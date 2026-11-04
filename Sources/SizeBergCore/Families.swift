import Darwin
import Foundation

/// Fixed-size bit set of group ids. The last bit stands for "outside the scanned folders".
struct GroupSet: Hashable {
    static let capacity = 256
    static let outsideIndex = capacity - 1
    static let maxGroups = capacity - 1

    private var a: UInt64 = 0
    private var b: UInt64 = 0
    private var c: UInt64 = 0
    private var d: UInt64 = 0

    init() {}

    init(_ group: Int) {
        insert(group)
    }

    mutating func insert(_ group: Int) {
        let bit = UInt64(1) << UInt64(group % 64)
        switch group / 64 {
        case 0: a |= bit
        case 1: b |= bit
        case 2: c |= bit
        default: d |= bit
        }
    }

    mutating func formUnion(_ other: GroupSet) {
        a |= other.a
        b |= other.b
        c |= other.c
        d |= other.d
    }

    var count: Int {
        a.nonzeroBitCount + b.nonzeroBitCount + c.nonzeroBitCount + d.nonzeroBitCount
    }

    var members: [Int] {
        var result: [Int] = []
        for (wordIndex, word) in [a, b, c, d].enumerated() {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                result.append(wordIndex * 64 + bit)
                remaining &= remaining - 1
            }
        }
        return result
    }
}

/// Files that share blocks: an APFS clone family, or the links of one inode.
struct Family {
    static let unsetBucket: Int32 = -2
    static let mixedBuckets: Int32 = -1

    var sharedBytes: Int64 = 0
    var groups = GroupSet()
    /// The one bucket holding every member, or `mixedBuckets`.
    var bucket: Int32 = Family.unsetBucket
    var firstBucket: Int32 = Family.unsetBucket
    var firstGroup: Int32 = 0
    var members: UInt32 = 0
    /// Link count for hard links, full-clone reference count for clones. Zero when unknown.
    /// More expected than found means copies outside the scan hold the blocks.
    var expectedMembers: UInt32 = 0
    /// Set when some member's blocks are also held by clones the family cannot see.
    var sharesBlocksOutside = false
    var firstDevice: Int32 = 0
    var firstInode: UInt64 = 0

    mutating func add(sharedBytes bytes: Int64, group: Int, bucket newBucket: Int, device: Int32, inode: UInt64) {
        sharedBytes = max(sharedBytes, bytes)
        groups.insert(group)
        let incoming = Int32(newBucket)
        if bucket == Family.unsetBucket {
            bucket = incoming
            firstBucket = incoming
            firstGroup = Int32(group)
            firstDevice = device
            firstInode = inode
        } else if bucket != incoming {
            bucket = Family.mixedBuckets
        }
        members += 1
    }
}

/// A file object on one volume: the inode for hard links, the clone id for clones.
/// Ids repeat across volumes, so the device is part of the key.
struct FileKey: Hashable {
    var device: Int32
    var id: UInt64
}

/// Families keyed by clone id or inode, split into shards by key.
/// One thread builds each shard, so no locks are needed.
final class FamilyTable: @unchecked Sendable {
    final class Shard {
        var clones: [FileKey: Family] = [:]
        var hardLinks: [FileKey: Family] = [:]
    }

    static let shardBits: UInt64 = 5
    static let shardCount = 1 << Int(shardBits)

    let shards: [Shard] = (0..<FamilyTable.shardCount).map { _ in Shard() }

    static func shardIndex(for key: UInt64) -> Int {
        Int((key &* 0x9E37_79B9_7F4A_7C15) >> (64 - shardBits))
    }
}

/// Reads the current copy count of one file by inode, through /.vol/<device>/<inode>:
/// full clones of its data (ATTR_CMNEXT_CLONE_REFCNT) for a clone, the link count for a hard link.
final class CopyCountProbe {
    // ATTR_CMNEXT_CLONE_REFCNT, read through forkattr with FSOPT_ATTR_CMN_EXTENDED.
    private static let cloneCountBit: attrgroup_t = 0x0000_1000
    // FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW
    private static let options: UInt32 = 0x20 | 0x1
    private static let expectedLength: UInt32 = 4 + 4

    private var request = attrlist()
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)

    init() {
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = Self.cloneCountBit
    }

    deinit {
        buffer.deallocate()
    }

    func copies(of entry: SharedEntry, device: Int32) -> UInt16? {
        let path = "/.vol/\(device)/\(entry.inode)"
        if entry.isHardLink {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return UInt16(clamping: info.st_nlink)
        }
        guard getattrlist(path, &request, buffer, 16, Self.options) == 0,
              buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == Self.expectedLength else { return nil }
        return UInt16(clamping: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
    }
}

/// Reads ATTR_CMNEXT_PRIVATESIZE for single files by inode, through /.vol/<device>/<inode>.
/// Used only for clones whose siblings the scan did not see. One probe per thread.
final class PrivateSizeProbe {
    // ATTR_CMNEXT_PRIVATESIZE, read through forkattr with FSOPT_ATTR_CMN_EXTENDED.
    private static let privateSizeBit: attrgroup_t = 0x0000_0008
    // FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW
    private static let options: UInt32 = 0x20 | 0x1
    private static let expectedLength: UInt32 = 4 + 8

    private var request = attrlist()
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)

    init() {
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = Self.privateSizeBit
    }

    deinit {
        buffer.deallocate()
    }

    func privateBytes(device: Int32, inode: UInt64) -> Int64? {
        guard getattrlist("/.vol/\(device)/\(inode)", &request, buffer, 32, Self.options) == 0,
              buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == Self.expectedLength else { return nil }
        return buffer.loadUnaligned(fromByteOffset: 4, as: Int64.self)
    }
}
