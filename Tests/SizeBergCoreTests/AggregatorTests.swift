@testable import SizeBergCore
import Testing

/// Accounting rules for shared blocks. Each case is a way the scan could call bytes freeable that are not.
struct AggregatorTests {
    private static let block = SharedEntry.blockSize
    private static let source = BucketKind.source.rawValue

    private static func scan(device: Int32 = 1, _ entries: [SharedEntry]) -> GroupScan {
        var scan = GroupScan()
        scan.device = device
        scan.entries = entries
        for entry in entries where !entry.isHardLink {
            scan.apparentBytes[Self.source] += entry.allocatedBytes
        }
        scan.fileCounts[Self.source] = entries.count
        return scan
    }

    private static func clone(_ id: UInt64, inode: UInt64, copies: UInt32, blocks: Int64 = 10) -> SharedEntry {
        SharedEntry(cloneID: id, inode: inode, allocatedBytes: blocks * block, copies: copies, kind: .source)
    }

    private static func set(_ groups: Int..., outside: Bool = false) -> GroupSet {
        var set = GroupSet()
        groups.forEach { set.insert($0) }
        if outside {
            set.insert(GroupSet.outsideIndex)
        }
        return set
    }

    @Test(arguments: [
        // Both full clones found: deleting both groups frees the blocks.
        (copies: UInt32(2), outside: false),
        // A third full clone outside the scan keeps the blocks.
        (copies: UInt32(3), outside: true),
    ])
    func twoClonesFreeOnlyWhenNoOtherCopyExists(copies: UInt32, outside: Bool) {
        let result = Aggregator(scans: [
            Self.scan([Self.clone(7, inode: 100, copies: copies)]),
            Self.scan([Self.clone(7, inode: 101, copies: copies)]),
        ]).run()

        #expect(result.sets[Self.set(0, 1, outside: outside)]?.bytes == 10 * Self.block)
        #expect(result.freeableAloneBytes.reduce(0, +) == 0)
    }

    @Test func singleCloneWithCopiesElsewhereFreesNothing() {
        let result = Aggregator(scans: [Self.scan([Self.clone(7, inode: 100, copies: 4)])]).run()

        #expect(result.freeableAloneBytes.reduce(0, +) == 0)
        #expect(result.sets[Self.set(0, outside: true)]?.bytes == 10 * Self.block)
        #expect(result.privateSizes.isEmpty)
    }

    @Test func lastCloneSharingWithChangedCopiesIsFlagged() {
        // APFS says 4 of 10 blocks are private, so a copy changed after cloning holds the other 6.
        let known: [FileKey: KnownPrivateSize] = [
            FileKey(device: 1, id: 7): KnownPrivateSize(cloneID: 7, inode: 100, privateBytes: 4 * Self.block, blocks: 10, device: 1),
        ]
        let result = Aggregator(scans: [Self.scan([Self.clone(7, inode: 100, copies: 1)])], knownPrivateSizes: known).run()

        #expect(result.freeableAloneBytes.reduce(0, +) == 4 * Self.block)
        #expect(result.changedCloneBytes == 6 * Self.block)
        #expect(result.changedCloneFiles == 1)
    }

    @Test func hardLinkedCloneNeverCountsAsFreeable() {
        let flags = SharedEntry.hardLinkFlag | SharedEntry.clonedElsewhereFlag
        let links = [100, 100].map { inode in
            SharedEntry(cloneID: 0, inode: UInt64(inode), allocatedBytes: 10 * Self.block, copies: 2, flags: flags, kind: .source)
        }
        let result = Aggregator(scans: [Self.scan(links)]).run()

        #expect(result.freeableAloneBytes.reduce(0, +) == 0)
        #expect(result.sets[Self.set(0, outside: true)]?.bytes == 10 * Self.block)
    }

    @Test func sameCloneIDOnTwoVolumesIsTwoFamilies() {
        let known: [FileKey: KnownPrivateSize] = [
            FileKey(device: 1, id: 7): KnownPrivateSize(cloneID: 7, inode: 100, privateBytes: 10 * Self.block, blocks: 10, device: 1),
            FileKey(device: 2, id: 7): KnownPrivateSize(cloneID: 7, inode: 100, privateBytes: 10 * Self.block, blocks: 10, device: 2),
        ]
        let result = Aggregator(
            scans: [
                Self.scan(device: 1, [Self.clone(7, inode: 100, copies: 1)]),
                Self.scan(device: 2, [Self.clone(7, inode: 100, copies: 1)]),
            ],
            knownPrivateSizes: known
        ).run()

        let kinds = BucketKind.allCases.count
        #expect(result.freeableAloneBytes[0 * kinds + Self.source] == 10 * Self.block)
        #expect(result.freeableAloneBytes[1 * kinds + Self.source] == 10 * Self.block)
    }
}
