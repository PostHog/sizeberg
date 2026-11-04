import Darwin
import Foundation
@testable import SizeBergCore
import Testing

/// Deleting a clone in a changed folder lowers the copy count of its sibling in an unchanged folder.
/// A rescan reuses that sibling's cached entry, so the count has to be read again or the sibling never frees.
struct CopyCountRefreshTests {
    /// A clone deleted in a changed folder (count goes down), or a clone made outside the scanned folders
    /// (count goes up while the cached entry still claims to be the only copy and would look freeable).
    @Test(arguments: [(keepClone: false, cachedCopies: UInt16(2), departed: true), (keepClone: true, cachedCopies: UInt16(1), departed: false)])
    func reusedEntryLearnsTheCurrentCopyCount(keepClone: Bool, cachedCopies: UInt16, departed: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original").path
        let clone = directory.appendingPathComponent("clone").path
        try Data(repeating: 7, count: 64 * 1024).write(to: URL(fileURLWithPath: original))
        #expect(clonefile(original, clone, 0) == 0)
        if !keepClone {
            try FileManager.default.removeItem(atPath: clone)
        }

        var info = stat()
        #expect(lstat(original, &info) == 0)
        var scan = GroupScan()
        scan.device = Int32(info.st_dev)
        scan.entries = [SharedEntry(cloneID: 7, inode: UInt64(info.st_ino), allocatedBytes: 64 * 1024, copies: UInt32(cachedCopies), kind: .source)]
        var scans = [0: scan]
        let key = FileKey(device: scan.device, id: 7)

        let recount = Scanner.refreshCopyCounts(in: &scans, sharedWith: departed ? [key] : [])

        #expect(recount.segments == [0])
        #expect(recount.changed == [key])
        #expect(scans[0]?.entries.first?.copies == (keepClone ? 2 : 1))
    }
}
