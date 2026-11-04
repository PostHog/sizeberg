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
            id: 0, name: "topic", kind: .worktree, path: worktree.path,
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
}
