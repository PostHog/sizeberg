import Darwin
import Foundation

/// The scratch folders Claude Code gives each session, in `/private/tmp/claude-<uid>/<project>/<session id>`.
/// `<project>` has the name of the session's transcript folder in `~/.claude/projects`, and
/// `<session id>.jsonl` there changes while the session runs. A session that has not changed for
/// `idleTime`, and whose folder no process uses, is over, so its scratch folder can go.
///
/// A session folder that holds git data stays: a clone made there can hold the only copy of its
/// commits. A session folder that holds a worktree is left out, since the worktree is an item of
/// its own whose delete checks for local work first.
struct ClaudeScratchpads {
    static let idleTime: TimeInterval = 24 * 60 * 60
    /// The name of the one scratchpad item in reports from 0.1.7 and older, which have no section.
    static let legacyItemName = "Claude Code scratchpads"

    struct Session: Equatable {
        var path: String
        /// The transcript folder name, like `-Users-me-workspace-app`.
        var project: String
        var id: String
        var isIdle: Bool
        /// The process that works in the folder or has a file open there, like "pid 123, claude".
        var holder: String?
        /// Checked only for idle sessions no process uses.
        var holdsGit: Bool

        var canDelete: Bool { isIdle && holder == nil && !holdsGit }
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

    /// Every session folder of this user, newest project folders first in name order.
    /// `inUse` comes from `AgentActivity.pathsInUse`, read once for every agent waste folder.
    func sessions(keeping worktrees: [String], inUse: [AgentActivity.ProcessFolder]) -> [Session] {
        // /private/tmp is shared by every account, so the root must be this user's own private folder.
        guard Self.isOwnFolder(root, privateToOwner: true) else { return [] }
        var result: [Session] = []
        for project in Self.children(of: root) where project.hasPrefix("-") {
            let projectFolder = root + "/" + project
            guard Self.isOwnFolder(projectFolder) else { continue }
            for session in Self.children(of: projectFolder) where UUID(uuidString: session) != nil {
                let folder = projectFolder + "/" + session
                guard Self.isOwnFolder(folder), !worktrees.contains(where: { $0.hasPrefix(folder + "/") }) else { continue }
                let holder = inUse.first { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }
                let idle = isIdle(folder)
                result.append(Session(
                    path: folder,
                    project: project,
                    id: session,
                    isIdle: idle,
                    holder: holder.map { "pid \($0.pid), \($0.name)" },
                    // The check reads the whole folder, so it runs only where it can change the answer.
                    holdsGit: idle && holder == nil && holdsGitData(folder)
                ))
            }
        }
        return result
    }

    /// Checks the folders again right before they are deleted: the scan may be days old.
    func reasonToSkip(_ folders: [String]) -> String? {
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0) }
        let inUse = AgentActivity.pathsInUse(under: existing)
        for folder in existing {
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
            if let holder = TempLeftovers.holder(of: folder, in: inUse) {
                return "A running process uses session \(name) (\(holder))."
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
