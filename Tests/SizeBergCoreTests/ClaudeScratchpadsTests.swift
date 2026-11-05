import Foundation
@testable import SizeBergCore
import Testing

/// Deleting the scratch folder of a session that still runs breaks that session, and deleting one
/// that holds a worktree skips the worktree's checks for local work.
struct ClaudeScratchpadsTests {
    @Test func offersOnlyIdleSessionsWithoutWorktrees() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("tmp").path
        let projects = base.appendingPathComponent("projects").path
        let project = "-Users-me-code-app"
        let idle = UUID().uuidString, running = UUID().uuidString, started = UUID().uuidString, holdsWorktree = UUID().uuidString
        for session in [idle, running, started, holdsWorktree] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(session)/scratchpad", withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: "\(root)/bash-edit-diff/1234", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(projects)/\(project)", withIntermediateDirectories: true)
        for session in [idle, running, holdsWorktree] {
            FileManager.default.createFile(atPath: "\(projects)/\(project)/\(session).jsonl", contents: Data())
        }

        let later = Date().addingTimeInterval(ClaudeScratchpads.idleTime + 60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(projects)/\(project)/\(running).jsonl")
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(root)/\(project)/\(started)/scratchpad")
        let worktree = "\(root)/\(project)/\(holdsWorktree)/scratchpad/app-copy"

        let sessions = ClaudeScratchpads(root: root, projectsFolder: projects, now: later).sessions(keeping: [worktree])

        #expect(sessions == .init(idle: ["\(root)/\(project)/\(idle)"], activeCount: 2))
    }
}
