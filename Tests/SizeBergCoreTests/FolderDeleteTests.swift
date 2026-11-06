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
}
