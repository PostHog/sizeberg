import Foundation
@testable import SizeBergCore
import Testing

/// A worktree an agent is working in must not look idle: its cleanup value drops to zero and the
/// cleanup skips it. Both are only as good as the mapping from transcripts to worktrees.
struct AgentActivityTests {
    @Test func transcriptsMapToTheirWorktrees() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let now = Date()
        let named = "/Users/me/workspace/worktrees/ph_3"
        let subagent = "/Users/me/workspace/repo/.claude/worktrees/agent-a2cd72c00528f29a1"
        let idle = "/Users/me/workspace/worktrees/quiet"
        func transcript(_ path: String, minutesAgo: Double) throws {
            let url = projects.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
        }
        // A session started in the worktree: folder named after its path, "_" turned into "-" as well.
        try transcript("-Users-me-workspace-worktrees-ph-3/1b2c.jsonl", minutesAgo: 1)
        // A subagent with a worktree of its own, filed under the session that started it.
        try transcript("-Users-me-workspace-repo/9f8e/subagents/agent-a2cd72c00528f29a1.jsonl", minutesAgo: 90)
        try transcript("-Users-me-workspace-worktrees-quiet/7a6b.jsonl", minutesAgo: 600)

        let states = AgentActivity(projectsFolder: projects, now: now).states(of: [named, subagent, idle])

        #expect(states[named]?.isWorking == true)
        #expect(states[subagent]?.isWorking == false)
        #expect(states[subagent]?.lastActive.map { abs($0.timeIntervalSince(now) + 90 * 60) < 2 } == true)
        #expect(states[idle]?.isWorking == false)
    }

    /// Claude Code's native binary is stored under its version number, so its process name is not "claude".
    @Test(arguments: [
        ("/Users/me/.local/share/claude/versions/2.1.318", true),
        ("/opt/homebrew/bin/codex", true),
        ("/usr/bin/zsh", false),
    ])
    func agentProcessesAreFoundByExecutable(path: String, isAgent: Bool) {
        #expect(AgentActivity.isAgent(executable: path) == isAgent)
    }
}
