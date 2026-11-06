import Foundation
@testable import SizeBergCore
import Testing

/// Folders next to repositories are offered for deletion only where they look like leftovers.
/// Someone with a few repositories and their own projects beside them must not be told to delete
/// those projects, and neither must anyone whose Documents folder holds a repository.
struct FolderDeleteTests {
    @Test(arguments: [
        (repositories: 20, folders: 5, inDocuments: false, offered: true),
        (repositories: 40, folders: 20, inDocuments: false, offered: false),
        (repositories: 3, folders: 1, inDocuments: false, offered: false),
        (repositories: 20, folders: 1, inDocuments: true, offered: false),
    ])
    func foldersAreOfferedOnlyAmongManyRepositories(repositories: Int, folders: Int, inDocuments: Bool, offered: Bool) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(inDocuments ? "Documents" : "code")
        for index in 0..<repositories {
            let repo = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = Shell.run("/usr/bin/git", ["init", "-q", repo.path])
        }
        for index in 0..<folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder-\(index)"), withIntermediateDirectories: true)
        }

        let specs = Discovery(roots: [root.path], home: home.path, git: GitInspector()).discover()

        let projects = specs.filter { $0.kind == .project }
        #expect(projects.count == folders)
        #expect(projects.allSatisfy { ($0.cleanupCommand != nil) == offered })
    }

    /// A plain folder that holds worktrees, like ~/workspace/worktrees, must never go with rm -rf:
    /// that skips the checks for uncommitted and unpushed work the worktrees get as items.
    @Test func folderHoldingGitDataIsNeitherOfferedNorDeleted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("code")
        for index in 0..<20 {
            let repo = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = Shell.run("/usr/bin/git", ["init", "-q", repo.path])
        }
        let holder = root.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: holder.appendingPathComponent("feature/.git"), withIntermediateDirectories: true)

        let specs = Discovery(roots: [root.path], home: home.path, git: GitInspector()).discover()
        let step = CleanupStep(
            groupIDs: [0], name: "worktrees", kind: .project, path: holder.path,
            command: "rm -rf \(shellQuote(holder.path))", expectedBytes: 0
        )

        #expect(specs.first { $0.paths == [holder.path] }?.cleanupCommand == nil)
        #expect(CleanupRunner.run(step) == .skipped("Holds a git repository or worktree, which rm -rf would delete without its checks."))
        #expect(FileManager.default.fileExists(atPath: holder.appendingPathComponent("feature/.git").path))
    }
}
