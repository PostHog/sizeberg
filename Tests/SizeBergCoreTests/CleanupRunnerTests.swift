import Foundation
@testable import SizeBergCore
import Testing

/// The scan can be minutes old when a cleanup runs. A worktree that gained work since then must survive.
struct CleanupRunnerTests {
    private static func git(_ arguments: [String], in directory: URL) throws {
        let result = Shell.run(Shell.find("git") ?? "/usr/bin/git", ["-C", directory.path] + arguments, mergeErrors: true)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
    }

    /// A clone of a bare remote with one pushed commit, and a worktree at that commit.
    private static func repoWithWorktree() throws -> (root: URL, repo: URL, worktree: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "--bare", "-b", "main"], in: remote)
        try git(["clone", remote.path, repo.path], in: root)
        try Data("hello\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        try git(["add", "file.txt"], in: repo)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "first"], in: repo)
        try git(["push", "origin", "main"], in: repo)
        try git(["worktree", "add", "-b", "topic", worktree.path, "origin/main"], in: repo)
        return (root, repo, worktree)
    }

    private static func step(repo: URL, worktree: URL) -> CleanupStep {
        CleanupStep(
            groupIDs: [0], name: "topic", kind: .worktree, path: worktree.path,
            command: "git -C \(shellQuote(repo.path)) worktree remove \(shellQuote(worktree.path))", expectedBytes: 0
        )
    }

    @Test func cleanWorktreeIsRemoved() throws {
        let (root, repo, worktree) = try Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CleanupRunner.run(Self.step(repo: repo, worktree: worktree)) == .done)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test func worktreeWithNewWorkIsSkipped() throws {
        let (root, repo, worktree) = try Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not committed\n".utf8).write(to: worktree.appendingPathComponent("draft.txt"))

        #expect(CleanupRunner.run(Self.step(repo: repo, worktree: worktree)) == .skipped("Has uncommitted changes now."))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("draft.txt").path))
    }

    /// A trim deletes rebuildable folders from a checkout that stays. A committed dist folder must survive it.
    @Test func trimKeepsFoldersThatHoldTrackedFiles() throws {
        let (root, repo, _) = try Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let dist = repo.appendingPathComponent("dist")
        let modules = repo.appendingPathComponent("node_modules")
        for folder in [dist, modules] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("built\n".utf8).write(to: folder.appendingPathComponent("index.js"))
        }
        try Self.git(["add", "dist"], in: repo)
        try Self.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "ship dist"], in: repo)
        let folders = [dist.path, modules.path]
        let step = CleanupStep(
            groupIDs: [0], name: "repo", kind: .mainCheckout, path: repo.path,
            command: CleanupRunner.trimCommand(folders), expectedBytes: 0, isTrim: true, folders: folders
        )

        #expect(CleanupRunner.run(step) == .partlyDone("Kept 1 of 2 folders: they are gone or hold files git tracks."))
        #expect(FileManager.default.fileExists(atPath: dist.appendingPathComponent("index.js").path))
        #expect(!FileManager.default.fileExists(atPath: modules.path))
    }

    /// Missing worktrees of one repository share one prune command. Every one of them must stay in the plan.
    @Test func itemsSharingACommandStayInThePlan() {
        let groups = (0..<3).map { id in
            GroupReport(
                id: id, kind: .worktree, name: "gone-\(id)", paths: ["/repo/gone-\(id)"], git: nil, buckets: [],
                apparentBytes: 0, privateBytes: 0, freeableAloneBytes: 0, selectable: true,
                cleanupCommand: "git -C '/repo' worktree prune", note: nil
            )
        }
        let report = Report(
            scannedAt: Date(), durationSeconds: 1, roots: [], fileCount: 0, errorCount: 0,
            volume: VolumeInfo(totalBytes: 0, freeBytes: 0, availableForImportantUsageBytes: nil),
            localSnapshots: [], groups: groups, sharedSets: []
        )

        let plan = CleanupRunner.plan(for: report, selection: [0, 1, 2])

        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.groupIDs == [0, 1, 2])
        #expect(plan.manual.isEmpty)
    }

    /// Build output chosen with a worktree that is deleted anyway: the worktree must not also be trimmed,
    /// and its build output must count once.
    @Test func buildOutputSkipsItemsThatAreDeleted() {
        let groups = (0..<2).map { id in
            GroupReport(
                id: id, kind: .worktree, name: "tree-\(id)", paths: ["/repo/tree-\(id)"], git: nil,
                buckets: [BucketReport(
                    kind: .buildOutput, apparentBytes: 300, privateBytes: 300, freeableAloneBytes: 300, fileCount: 1,
                    folders: ["/repo/tree-\(id)/dist"]
                )],
                apparentBytes: 1_000, privateBytes: 1_000, freeableAloneBytes: 1_000, selectable: true,
                cleanupCommand: "git -C '/repo' worktree remove '/repo/tree-\(id)'", note: nil
            )
        }
        let report = Report(
            scannedAt: Date(), durationSeconds: 1, roots: [], fileCount: 0, errorCount: 0,
            volume: VolumeInfo(totalBytes: 0, freeBytes: 0, availableForImportantUsageBytes: nil),
            localSnapshots: [], groups: groups, sharedSets: []
        )
        let selection: Set<Int> = [0, Report.buildOutputID]

        let plan = CleanupRunner.plan(for: report, selection: selection)

        #expect(plan.steps.map(\.isTrim) == [false, true])
        #expect(plan.steps.last?.folders == ["/repo/tree-1/dist"])
        #expect(report.freeableBytes(selection: selection) == 1_300)
    }
}
