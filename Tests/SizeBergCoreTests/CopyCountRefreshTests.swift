import Darwin
import Foundation
@testable import SizeBergCore
import Testing

/// Deleting a clone in a changed folder lowers the copy count of its sibling in an unchanged folder.
/// A rescan reuses that sibling's cached entry, so the count has to be read again or the sibling never frees.
struct CopyCountRefreshTests {
    @Test func reusedEntryLearnsThatItsCloneWasDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original").path
        let clone = directory.appendingPathComponent("clone").path
        try Data(repeating: 7, count: 64 * 1024).write(to: URL(fileURLWithPath: original))
        #expect(clonefile(original, clone, 0) == 0)
        try FileManager.default.removeItem(atPath: clone)

        var info = stat()
        #expect(lstat(original, &info) == 0)
        var scan = GroupScan()
        scan.device = Int32(info.st_dev)
        scan.entries = [SharedEntry(cloneID: 7, inode: UInt64(info.st_ino), allocatedBytes: 64 * 1024, copies: 2, kind: .source)]
        var scans = [0: scan]

        let recounted = Scanner.refreshCopyCounts(in: &scans, sharedWith: [FileKey(device: scan.device, id: 7)])

        #expect(recounted == [0])
        #expect(scans[0]?.entries.first?.copies == 1)
    }
}
