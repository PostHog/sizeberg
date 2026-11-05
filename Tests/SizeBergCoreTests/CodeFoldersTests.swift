import Foundation
@testable import SizeBergCore
import Testing

/// People keep their code anywhere. A missed folder means its worktrees never show up; a folder found
/// too deep splits one project into many items.
struct CodeFoldersTests {
    @Test func findsTheFoldersThatHoldRepositories() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for repo in [
            "code/app", "code/app/vendor/lib", // a repository inside another is not a code folder of its own
            "Documents/GitHub/site",
            "dotfiles",
            "Library/Application Support/tool/repo", "Pictures/old", ".hidden/repo", // never searched
            "notes/a/b/c/d/e/f/g/too-deep",
        ] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(repo + "/.git"), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("code/not-a-repo"), withIntermediateDirectories: true)

        let found = CodeFolders.find(home: home.path)

        #expect(found.roots == ["code", "Documents/GitHub"].map { home.appendingPathComponent($0).path }.sorted())
        #expect(found.repositories == [home.appendingPathComponent("dotfiles").path])
    }
}
