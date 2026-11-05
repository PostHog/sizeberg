import Darwin
import Foundation

/// The scratch folders Claude Code gives each session, in `/private/tmp/claude-<uid>/<project>/<session id>`.
/// `<project>` has the name of the session's transcript folder in `~/.claude/projects`, and
/// `<session id>.jsonl` there changes while the session runs. A session that has not changed for
/// `idleTime` is over, so its scratch folder can go.
///
/// A session folder that holds a worktree stays: the worktree is an item of its own, and its
/// delete checks for uncommitted and unpushed work first.
struct ClaudeScratchpads {
    static let idleTime: TimeInterval = 3 * 24 * 60 * 60

    struct Sessions: Equatable {
        var idle: [String]
        var activeCount: Int
    }

    let root: String
    let projectsFolder: String
    let now: Date

    init(root: String = "/private/tmp/claude-\(getuid())",
         projectsFolder: String = NSHomeDirectory() + "/.claude/projects",
         now: Date = Date()) {
        self.root = root
        self.projectsFolder = projectsFolder
        self.now = now
    }

    func sessions(keeping worktrees: [String]) -> Sessions {
        var result = Sessions(idle: [], activeCount: 0)
        for project in Self.children(of: root) where project.hasPrefix("-") {
            for session in Self.children(of: root + "/" + project) where UUID(uuidString: session) != nil {
                let folder = root + "/" + project + "/" + session
                if worktrees.contains(where: { $0.hasPrefix(folder + "/") }) {
                    continue
                }
                if isIdle(folder: folder, transcript: projectsFolder + "/" + project + "/" + session) {
                    result.idle.append(folder)
                } else {
                    result.activeCount += 1
                }
            }
        }
        result.idle.sort()
        return result
    }

    /// A new session has a scratch folder before it has a transcript, so the folders count as activity too.
    private func isIdle(folder: String, transcript: String) -> Bool {
        let touched = [transcript + ".jsonl", transcript, folder, folder + "/scratchpad"].compactMap(Self.modified)
        guard let last = touched.max() else { return true }
        return now.timeIntervalSince(last) >= Self.idleTime
    }

    private static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    private static func children(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }
}
