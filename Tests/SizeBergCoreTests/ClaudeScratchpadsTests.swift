import Foundation
@testable import SizeBergCore
import Testing

/// Deleting the scratch folder of a session that still runs breaks that session, and deleting one
/// that holds a clone or worktree can delete the only copy of its commits.
struct ClaudeScratchpadsTests {
    @Test func offersOnlyIdleSessionsWithoutWorktrees() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("tmp").path
        let projects = base.appendingPathComponent("projects").path
        let project = "-Users-me-code-app"
        let idle = UUID().uuidString, running = UUID().uuidString, started = UUID().uuidString
        let holdsWorktree = UUID().uuidString, holdsClone = UUID().uuidString
        for session in [idle, running, started, holdsWorktree, holdsClone] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(session)/scratchpad", withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(holdsClone)/scratchpad/app/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/bash-edit-diff/1234", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(projects)/\(project)", withIntermediateDirectories: true)
        for session in [idle, running, holdsWorktree] {
            FileManager.default.createFile(atPath: "\(projects)/\(project)/\(session).jsonl", contents: Data())
        }

        let later = Date().addingTimeInterval(ClaudeScratchpads.idleTime + 60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(projects)/\(project)/\(running).jsonl")
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(root)/\(project)/\(started)/scratchpad")
        let worktree = "\(root)/\(project)/\(holdsWorktree)/scratchpad/app-copy"

        let scratchpads = ClaudeScratchpads(root: root, projectsFolder: projects, now: later)
        let sessions = scratchpads.sessions(keeping: [worktree])

        #expect(sessions == .init(idle: ["\(root)/\(project)/\(idle)"], activeCount: 2))
        #expect(scratchpads.reasonToSkip(sessions.idle) == nil)
        try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(idle)/scratchpad/new-clone/.git", withIntermediateDirectories: true)
        #expect(scratchpads.reasonToSkip(sessions.idle) == "Session \(idle) holds a git repository now.")
    }

    /// /private/tmp is shared, so another account could create the root first and point it at this user's files.
    @Test func ignoresARootThatOthersCanWriteTo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/-Users-me-code-app/\(UUID().uuidString)", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root)

        let sessions = ClaudeScratchpads(root: root, projectsFolder: root, now: Date().addingTimeInterval(ClaudeScratchpads.idleTime + 60)).sessions(keeping: [])

        #expect(sessions.idle.isEmpty)
    }
}
