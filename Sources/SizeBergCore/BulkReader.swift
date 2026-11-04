import Darwin

struct DirectoryEntry {
    /// Set for directories only: the walk needs names to descend, and decoding millions of file names costs time.
    var name: String?
    var type: UInt32
    var device: Int32
    var inode: UInt64
    var linkCount: UInt32
    var allocatedBytes: Int64
    var cloneID: UInt64
    /// Set once a file was cloned. Files without it hold all their blocks alone.
    /// Also set when the file system did not say, so unknown sharing is never counted as private.
    var mayShareBlocks: Bool
    /// Full clones of this file's data on the volume, this file included. Zero when the file system did not say.
    var cloneReferenceCount: UInt32
}

/// Reads one directory with getattrlistbulk: names, inode data, allocation and APFS clone data
/// for every entry in a few system calls, instead of a path lookup plus lstat per file.
/// It skips ATTR_CMNEXT_PRIVATESIZE on purpose: that one makes APFS walk each file's extents and
/// doubles the scan time. Clone families and reference counts give the same answer for full clones;
/// see `FileProbe` for the rest.
final class BulkReader {
    static let regularFile: UInt32 = 1
    static let directory: UInt32 = 2

    // ATTR_CMNEXT_* bits, read through forkattr with FSOPT_ATTR_CMN_EXTENDED.
    private static let cloneIDBit: attrgroup_t = 0x0000_0100
    private static let extendedFlagsBit: attrgroup_t = 0x0000_0200
    private static let cloneReferenceCountBit: attrgroup_t = 0x0000_1000
    /// EF_MAY_SHARE_BLOCKS in the extended flags.
    private static let mayShareBlocksFlag: UInt64 = 0x1
    /// FSOPT_ATTR_CMN_EXTENDED. Without FSOPT_PACK_INVAL_ATTRS, a record holds only the attributes
    /// its returned set names, so the parser can follow that set.
    private static let options: UInt64 = 0x20
    /// 64 KiB, 256 KiB and 1 MiB measured the same; most directories fit in one call either way.
    private static let bufferSize = 256 * 1024

    private var request = attrlist()
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: BulkReader.bufferSize, alignment: 8)

    init() {
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        request.forkattr = Self.cloneIDBit | Self.extendedFlagsBit | Self.cloneReferenceCountBit
    }

    deinit {
        buffer.deallocate()
    }

    /// Calls `body` for each entry. Returns false when the directory could not be read to the end.
    func read(directory fd: Int32, _ body: (DirectoryEntry) -> Void) -> Bool {
        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, Self.options)
            if count < 0 {
                return false
            }
            if count == 0 {
                return true
            }
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                body(parse(record))
                record += length
            }
        }
    }

    /// Fields come in attribute bit order, and only the ones in the returned set are present:
    /// directories carry no file fields, for example.
    private func parse(_ record: UnsafeRawPointer) -> DirectoryEntry {
        var cursor = record + 4
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size

        var nameField: UnsafeRawPointer?
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            nameField = cursor
            cursor += MemoryLayout<attrreference_t>.size
        }
        var device: Int32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            device = cursor.loadUnaligned(as: Int32.self)
            cursor += 4
        }
        var type: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            type = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        var inode: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            inode = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }

        var linkCount: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            linkCount = cursor.loadUnaligned(as: UInt32.self)
            cursor += 4
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocated = cursor.loadUnaligned(as: Int64.self)
            cursor += 8
        }
        var cloneID: UInt64 = 0
        if returned.forkattr & Self.cloneIDBit != 0 {
            cloneID = cursor.loadUnaligned(as: UInt64.self)
            cursor += 8
        }
        var mayShareBlocks = true
        if returned.forkattr & Self.extendedFlagsBit != 0 {
            mayShareBlocks = cursor.loadUnaligned(as: UInt64.self) & Self.mayShareBlocksFlag != 0
            cursor += 8
        }
        var cloneReferenceCount: UInt32 = 0
        if returned.forkattr & Self.cloneReferenceCountBit != 0 {
            cloneReferenceCount = cursor.loadUnaligned(as: UInt32.self)
        }

        var name: String?
        if type == Self.directory, let nameField {
            let offset = Int(nameField.loadUnaligned(as: Int32.self))
            name = String(cString: (nameField + offset).assumingMemoryBound(to: CChar.self))
        }
        return DirectoryEntry(
            name: name,
            type: type,
            device: device,
            inode: inode,
            linkCount: linkCount,
            allocatedBytes: allocated,
            cloneID: cloneID,
            mayShareBlocks: mayShareBlocks,
            cloneReferenceCount: cloneReferenceCount
        )
    }
}
