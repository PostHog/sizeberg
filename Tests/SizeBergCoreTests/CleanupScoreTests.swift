import Foundation
@testable import SizeBergCore
import Testing

/// The ranking must put quiet finished work first and never push items with local work up by size alone.
struct CleanupScoreTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let gigabyte: Int64 = 1_000_000_000

    private static func worktree(_ name: String, gigabytes: Int64, quietDays: Double, merged: Bool?, uncommitted: Bool? = nil) -> GroupReport {
        let git = GitInfo(
            repoPath: "/repo",
            branch: name,
            headDate: nil,
            lastActive: now.addingTimeInterval(-quietDays * 86_400),
            upstreamGone: false,
            mergedIntoDefault: merged,
            hasUncommittedChanges: uncommitted,
            hasUnpushedCommits: false,
            status: .active
        )
        return GroupReport(
            id: 0, kind: .worktree, name: name, paths: ["/repo/" + name], git: git, buckets: [],
            apparentBytes: gigabytes * gigabyte, privateBytes: 0, freeableAloneBytes: gigabytes * gigabyte,
            selectable: true, cleanupCommand: nil, note: nil
        )
    }

    @Test func quietMergedWorkRanksAboveBiggerItemsInUseOrWithLocalWork() {
        let inUse = Self.worktree("in-use", gigabytes: 6, quietDays: 0.2, merged: nil)
        let finished = Self.worktree("finished", gigabytes: 2, quietDays: 10, merged: true)
        let localWork = Self.worktree("local-work", gigabytes: 6, quietDays: 30, merged: false, uncommitted: true)

        let ranked = [inUse, localWork, finished]
            .sorted { $0.cleanupScore(now: Self.now)!.weightedBytes > $1.cleanupScore(now: Self.now)!.weightedBytes }
            .map(\.name)

        #expect(ranked == ["finished", "local-work", "in-use"])
        #expect(localWork.cleanupScore(now: Self.now)!.confidence < 0.31)
    }
}
