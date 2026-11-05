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
                    folders: [BuildFolder(path: "/repo/tree-\(id)/dist", bytes: 300)]
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

    /// Flox keeps its Python venv inside .flox/cache. Deleting the cache must leave the venv.
    @Test func cacheFolderKeepsTheVenvInsideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(".flox/cache")
        for folder in ["venv/lib", "go-build"] {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: cache.appendingPathComponent("upgrade-checks.json"))

        let folders = TrimFolder.excludingDependencies([
            TrimFolder(path: cache.path, kind: .caches),
            TrimFolder(path: cache.appendingPathComponent("venv").path, kind: .dependencies),
        ])

        #expect(folders.map(\.path) == ["go-build", "upgrade-checks.json"].map { cache.appendingPathComponent($0).path })
        #expect(folders.allSatisfy { $0.kind == .caches })
    }

    /// A big checkout has more build folders than one process takes as arguments, and Go's module
    /// cache is read-only. Both must still go, without crashing the app.
    @Test func trimRemovesThousandsOfFoldersAndReadOnlyOnes() throws {
        let (root, repo, _) = try Self.repoWithWorktree()
        defer {
            _ = Shell.run("/bin/chmod", ["-R", "u+w", root.path])
            try? FileManager.default.removeItem(at: root)
        }
        let folders = (0..<4_100).map { repo.appendingPathComponent("pkg\($0)/__pycache__") }
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let module = repo.appendingPathComponent(".flox/cache/go/pkg/mod/example@v1")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try Data("package example\n".utf8).write(to: module.appendingPathComponent("a.go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: module.path)
        let paths = folders.map(\.path) + [repo.appendingPathComponent(".flox/cache/go").path]
        let step = CleanupStep(
            groupIDs: [0], name: "repo", kind: .mainCheckout, path: repo.path,
            command: CleanupRunner.trimCommand(paths), expectedBytes: 0, isTrim: true, folders: paths
        )

        #expect(CleanupRunner.run(step) == .done)
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    /// Deleting build output skips what is not worth it or not ours to delete: a committed dist,
    /// and the thousands of small __pycache__ folders. The number shrinks to match.
    @Test func buildOutputLeavesTrackedAndSmallFolders() {
        let big = BuildFolder(path: "/repo/.turbo", bytes: 8_000_000)
        let small = BuildFolder(path: "/repo/app/__pycache__", bytes: 100_000)
        let committed = BuildFolder(path: "/repo/.github/actions/x/dist", bytes: 1_900_000)

        let choice = BuildFolder.choose([big, small, committed], tracked: [committed.path], freeable: 10_000_000)

        #expect(choice.folders == [big])
        #expect(choice.freeBytes == 8_000_000)
        #expect(choice.small == [small])
        #expect(choice.trackedCount == 1)
    }

    /// A dev server, an editor or a shell in a folder leaves no git trace; deleting under it breaks it.
    @Test func folderWithAProcessInItIsSkipped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        sleeper.currentDirectoryURL = folder.appendingPathComponent("src")
        try sleeper.run()
        defer { sleeper.terminate() }
        let step = CleanupStep(
            groupIDs: [0], name: "folder", kind: .project, path: folder.path,
            command: "rm -rf \(shellQuote(folder.path))", expectedBytes: 0
        )

        let outcome = CleanupRunner.run(step)

        #expect(outcome == .skipped("A running process is working in it (pid \(sleeper.processIdentifier), sleep)."))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    /// git worktree remove deletes ignored files without asking. Only the ones that would really be
    /// lost count: not rebuildable, and not the same as the main checkout's copy.
    @Test func ignoredFilesListOnlyWhatDeletingWouldLose() throws {
        let (root, repo, worktree) = try Self.repoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let write = { (folder: URL, path: String, text: String) in
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(worktree, ".gitignore", ".env*\nnotes.md\nnode_modules/\n.trunk/\n")
        try write(worktree, ".env", "SHARED=1\n")
        try write(repo, ".env", "SHARED=1\n")
        try write(worktree, ".env.local", "ONLY_HERE=1\n")
        try write(worktree, "notes.md", "half a thought\n")
        try write(worktree, "node_modules/pkg/index.js", "x\n")
        try write(worktree, ".trunk/out/log", "x\n")
        try Self.git(["add", ".gitignore"], in: worktree)
        try Self.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "ignore"], in: worktree)

        let lost = try #require(IgnoredFiles.lost(in: worktree.path, mainCheckout: repo.path))

        #expect(lost == [
            IgnoredFile(path: ".env.local", looksSecret: true),
            IgnoredFile(path: "notes.md", looksSecret: false),
        ])
    }
}
