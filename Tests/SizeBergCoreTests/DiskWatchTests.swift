import Foundation
@testable import SizeBergCore
import Testing

/// The menu bar runs all day, so a warning that repeats on every check, or never fires on a leak,
/// makes it useless. These pin when each warning fires and when it may fire again.
struct DiskWatchTests {
    private static let gigabyte: Int64 = 1_000_000_000
    private static let total = 1_000 * gigabyte
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func lowSpaceWarnsOnceUntilTheDiskRecovers() {
        var watch = DiskWatch()
        let readings: [Int64] = [150, 95, 90, 110, 95, 130, 80]
        let warned = readings.enumerated().map { index, free in
            watch.record(freeBytes: free * Self.gigabyte, totalBytes: Self.total, at: Self.start.addingTimeInterval(Double(index) * 6 * 3600))
                .contains { if case .lowSpace = $0 { return true } else { return false } }
        }

        // Hovering between 10% and 12% does not warn again; only going back above 12% re-arms it.
        #expect(warned == [false, true, false, false, false, false, true])
    }

    @Test func fastDropWarnsWithinAnHourOnly() {
        var watch = DiskWatch()
        let minutes = 60.0
        _ = watch.record(freeBytes: 400 * Self.gigabyte, totalBytes: Self.total, at: Self.start)
        let slow = watch.record(freeBytes: 385 * Self.gigabyte, totalBytes: Self.total, at: Self.start.addingTimeInterval(50 * minutes))
        let fast = watch.record(freeBytes: 370 * Self.gigabyte, totalBytes: Self.total, at: Self.start.addingTimeInterval(55 * minutes))
        // The drop was reported, so the next reading counts from 370 GB.
        let after = watch.record(freeBytes: 365 * Self.gigabyte, totalBytes: Self.total, at: Self.start.addingTimeInterval(60 * minutes))

        #expect(slow.isEmpty)
        #expect(fast == [.fastDrop(bytes: 30 * Self.gigabyte, minutes: 55)])
        #expect(after.isEmpty)
    }

    /// Build output inside a stale worktree goes with the worktree. Counting it twice would promise
    /// more in the menu than a cleanup frees.
    @Test func reclaimableCountsBuildOutputInStaleWorktreesOnce() {
        let git = GitInfo(repoPath: "/repo", branch: "old", headDate: nil, lastActive: nil, upstreamGone: false, mergedIntoDefault: true,
                          hasUncommittedChanges: false, hasUnpushedCommits: false, status: .stale)
        let build = BucketReport(kind: .buildOutput, apparentBytes: 10 * Self.gigabyte, privateBytes: 10 * Self.gigabyte, freeableAloneBytes: 10 * Self.gigabyte, fileCount: 1,
                                 folders: [BuildFolder(path: "/repo/old/target", bytes: 10 * Self.gigabyte)], foldersFreeBytes: 10 * Self.gigabyte)
        let stale = GroupReport(id: 0, kind: .worktree, name: "old", paths: ["/repo/old"], git: git, buckets: [build],
                                apparentBytes: 10 * Self.gigabyte, privateBytes: 10 * Self.gigabyte, freeableAloneBytes: 10 * Self.gigabyte,
                                selectable: true, cleanupCommand: "git worktree remove", note: nil)
        let report = Report(scannedAt: Self.start, durationSeconds: 1, roots: [], fileCount: 1, errorCount: 0,
                            volume: VolumeInfo(totalBytes: Self.total, freeBytes: 0, availableForImportantUsageBytes: nil),
                            localSnapshots: [], groups: [stale], sharedSets: [])

        #expect(report.reclaimable.totalBytes == 10 * Self.gigabyte)
    }
}
