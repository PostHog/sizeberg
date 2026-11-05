import Foundation
@testable import SizeBergCore
import Testing

/// A squash merge leaves the branch's own commits unmerged and on no remote, though the work landed.
/// Missing it keeps finished worktrees; a false match would delete a worktree with work in it.
struct SquashMergeTests {
    private static func git(_ arguments: [String], in directory: URL) throws {
        let result = Shell.run(Shell.find("git") ?? "/usr/bin/git", ["-C", directory.path, "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments, mergeErrors: true)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
    }

    @Test func squashMergedBranchIsFoundUntilItGetsANewCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("repo")
        let worktree = root.appendingPathComponent("topic")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Self.git(["init", "--bare", "-b", "main"], in: remote)
        try Self.git(["clone", remote.path, repo.path], in: root)
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        try Self.git(["add", "a.txt"], in: repo)
        try Self.git(["commit", "-m", "first"], in: repo)
        try Self.git(["push", "origin", "main"], in: repo)
        // Two commits on a branch, in a worktree, as a pull request would have them.
        try Self.git(["worktree", "add", "-b", "topic", worktree.path, "origin/main"], in: repo)
        for (file, text) in [("b.txt", "two\n"), ("a.txt", "one\nmore\n")] {
            try Data(text.utf8).write(to: worktree.appendingPathComponent(file))
            try Self.git(["add", file], in: worktree)
            try Self.git(["commit", "-m", "change \(file)"], in: worktree)
        }
        // The merge queue squashes them into one new commit on main, after another change landed first.
        try Data("other\n".utf8).write(to: repo.appendingPathComponent("c.txt"))
        try Self.git(["add", "c.txt"], in: repo)
        try Self.git(["commit", "-m", "unrelated"], in: repo)
        try Self.git(["merge", "--squash", "topic"], in: repo)
        try Self.git(["commit", "-m", "topic (#1)"], in: repo)
        try Self.git(["push", "origin", "main"], in: repo)
        try Self.git(["fetch", "origin"], in: worktree)
        let gitPath = try #require(Shell.find("git"))
        let head = { Shell.run(gitPath, ["-C", worktree.path, "rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines) }

        #expect(GitInspector.hasUnpushedCommits(at: worktree.path, git: gitPath))
        let found = GitInspector.squashMerge(at: worktree.path, head: head(), defaultRef: "origin/main", git: gitPath)
        #expect(found != nil && found?.hasPrefix("#") == false)

        // Work after the merge is not in it.
        try Data("later\n".utf8).write(to: worktree.appendingPathComponent("d.txt"))
        try Self.git(["add", "d.txt"], in: worktree)
        try Self.git(["commit", "-m", "after the merge"], in: worktree)
        #expect(GitInspector.squashMerge(at: worktree.path, head: head(), defaultRef: "origin/main", git: gitPath) == nil)
    }
}
