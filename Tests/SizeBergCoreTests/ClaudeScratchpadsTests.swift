import Foundation
@testable import SizeBergCore
import Testing

/// Deleting the scratch folder of a session that still runs breaks that session, and deleting one
/// that holds a clone or worktree can delete the only copy of its commits.
struct ClaudeScratchpadsTests {
    @Test func offersOnlyIdleUnusedSessionsWithoutGitData() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("tmp").path
        let projects = base.appendingPathComponent("projects").path
        let project = "-Users-me-code-app"
        let idle = UUID().uuidString, running = UUID().uuidString, started = UUID().uuidString
        let held = UUID().uuidString, holdsWorktree = UUID().uuidString, holdsClone = UUID().uuidString
        for session in [idle, running, started, held, holdsWorktree, holdsClone] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(session)/scratchpad", withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(holdsClone)/scratchpad/app/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(root)/bash-edit-diff/1234", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(projects)/\(project)", withIntermediateDirectories: true)
        for session in [idle, running, held, holdsWorktree] {
            FileManager.default.createFile(atPath: "\(projects)/\(project)/\(session).jsonl", contents: Data())
        }

        let later = Date().addingTimeInterval(ClaudeScratchpads.idleTime + 60)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(projects)/\(project)/\(running).jsonl")
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(root)/\(project)/\(started)/scratchpad")
        let worktree = "\(root)/\(project)/\(holdsWorktree)/scratchpad/app-copy"
        // An agent that went quiet but still has a file open, like a long build writing its log.
        let process = AgentActivity.ProcessFolder(pid: 42, executable: "/usr/bin/python3", folder: "\(root)/\(project)/\(held)/scratchpad/build.log")

        let scratchpads = ClaudeScratchpads(root: root, projectsFolder: projects, now: later)
        let sessions = scratchpads.sessions(keeping: [worktree], inUse: [process])

        #expect(!sessions.contains { $0.id == holdsWorktree })
        #expect(sessions.filter(\.canDelete).map(\.path) == ["\(root)/\(project)/\(idle)"])
        #expect(sessions.first { $0.id == held }?.holder == "pid 42, python3")
        #expect(Set(sessions.filter { !$0.isIdle }.map(\.id)) == [running, started])
        #expect(sessions.first { $0.id == holdsClone }?.holdsGit == true)
        #expect(scratchpads.reasonToSkip(["\(root)/\(project)/\(idle)"]) == nil)
        try FileManager.default.createDirectory(atPath: "\(root)/\(project)/\(idle)/scratchpad/new-clone/.git", withIntermediateDirectories: true)
        #expect(scratchpads.reasonToSkip(["\(root)/\(project)/\(idle)"]) == "Session \(idle) holds a git repository now.")
    }

    /// /private/tmp is shared, so another account could create the root first and point it at this user's files.
    @Test func ignoresARootThatOthersCanWriteTo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: "\(root)/-Users-me-code-app/\(UUID().uuidString)", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root)

        let sessions = ClaudeScratchpads(root: root, projectsFolder: root, now: Date().addingTimeInterval(ClaudeScratchpads.idleTime + 60))
            .sessions(keeping: [], inUse: [])

        #expect(sessions.isEmpty)
    }
}
