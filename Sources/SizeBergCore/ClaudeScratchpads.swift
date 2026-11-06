import Darwin
import Foundation

/// The scratch folders Claude Code gives each session, in `/private/tmp/claude-<uid>/<project>/<session id>`.
/// `<project>` has the name of the session's transcript folder in `~/.claude/projects`, and
/// `<session id>.jsonl` there changes while the session runs. A session that has not changed for
/// `idleTime` is over, so its scratch folder can go.
///
/// A session folder that holds git data stays: a clone made there can hold the only copy of its
/// commits, and a worktree is an item of its own whose delete checks for local work first.
struct ClaudeScratchpads {
    static let idleTime: TimeInterval = 3 * 24 * 60 * 60
    static let itemName = "Claude Code scratchpads"

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
        // /private/tmp is shared by every account, so the root must be this user's own private folder.
        guard Self.isOwnFolder(root, privateToOwner: true) else { return result }
        for project in Self.children(of: root) where project.hasPrefix("-") {
            let projectFolder = root + "/" + project
            guard Self.isOwnFolder(projectFolder) else { continue }
            for session in Self.children(of: projectFolder) where UUID(uuidString: session) != nil {
                let folder = projectFolder + "/" + session
                guard Self.isOwnFolder(folder), !worktrees.contains(where: { $0.hasPrefix(folder + "/") }) else { continue }
                guard isIdle(folder) else {
                    result.activeCount += 1
                    continue
                }
                if !holdsGitData(folder) {
                    result.idle.append(folder)
                }
            }
        }
        result.idle.sort()
        return result
    }

    /// Checks the folders again right before they are deleted: the scan may be days old.
    func reasonToSkip(_ folders: [String]) -> String? {
        for folder in folders where FileManager.default.fileExists(atPath: folder) {
            let name = (folder as NSString).lastPathComponent
            let project = (folder as NSString).deletingLastPathComponent
            guard (project as NSString).deletingLastPathComponent == root,
                  Self.isOwnFolder(root, privateToOwner: true), Self.isOwnFolder(project), Self.isOwnFolder(folder) else {
                return "\(name) is not a scratch folder of yours."
            }
            if !isIdle(folder) {
                return "Session \(name) was active again since the scan."
            }
            if holdsGitData(folder) {
                return "Session \(name) holds a git repository now."
            }
            if let process = AgentActivity.process(workingIn: folder) {
                return "A running process is working in session \(name) (pid \(process.pid), \(process.name))."
            }
        }
        return nil
    }

    /// A new session has a scratch folder before it has a transcript, so the folders count as activity too.
    private func isIdle(_ folder: String) -> Bool {
        let session = (folder as NSString).lastPathComponent
        let project = ((folder as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let transcript = projectsFolder + "/" + project + "/" + session
        let touched = [transcript + ".jsonl", transcript, folder, folder + "/scratchpad"].compactMap(Self.modified)
        guard let last = touched.max() else { return true }
        return now.timeIntervalSince(last) >= Self.idleTime
    }

    /// A real folder, not a symbolic link, owned by this user.
    private static func isOwnFolder(_ path: String, privateToOwner: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        return !privateToOwner || (info.st_mode & 0o077) == 0
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
