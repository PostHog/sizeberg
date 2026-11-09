import Darwin
import Foundation

/// When a coding agent last worked in a checkout, and whether one is working there now.
public struct AgentState: Codable, Sendable, Equatable {
    public var lastActive: Date?
    public var isWorking: Bool
}

/// Finds coding agents by what they leave on disk, without reading any transcript:
///
/// - Claude Code keeps a folder per working directory in `~/.claude/projects`, named after the path
///   with every character other than a letter or digit turned into `-`. Its `.jsonl` files change
///   while a session runs.
/// - A Claude Code subagent with a worktree of its own works in `.claude/worktrees/agent-<id>` and
///   writes `<session>/subagents/agent-<id>.jsonl`, so the worktree's folder name is the link.
/// - A running `claude` or `codex` process has its current directory in the checkout it works on.
struct AgentActivity {
    /// A transcript that changed this recently belongs to an agent that is still working.
    static let workingWindow: TimeInterval = 5 * 60

    let projectsFolder: URL
    let now: Date

    init(projectsFolder: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"), now: Date = Date()) {
        self.projectsFolder = projectsFolder
        self.now = now
    }

    /// One pass over the transcript folders and the process table, for every checkout at once.
    func states(of checkouts: [String]) -> [String: AgentState] {
        let transcripts = latestTranscripts()
        let workingFolders = Self.agentProcessFolders()
        var states: [String: AgentState] = [:]
        for path in checkouts {
            let name = (path as NSString).lastPathComponent
            let lastActive = [transcripts[Self.projectFolderName(for: path)], transcripts[name]].compactMap { $0 }.max()
            let processHere = workingFolders.contains { $0 == path || $0.hasPrefix(path + "/") }
            let recent = lastActive.map { now.timeIntervalSince($0) < Self.workingWindow } ?? false
            guard lastActive != nil || processHere else { continue }
            states[path] = AgentState(lastActive: lastActive, isWorking: processHere || recent)
        }
        return states
    }

    /// Claude Code's folder name for a working directory, like `-Users-me-workspace-app` for `/Users/me/workspace/app`.
    static func projectFolderName(for path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    /// Newest change per project folder name and per subagent id (`agent-<id>`).
    private func latestTranscripts() -> [String: Date] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let files = FileManager.default.enumerator(at: projectsFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [:] }
        var latest: [String: Date] = [:]
        let rootDepth = projectsFolder.standardizedFileURL.pathComponents.count
        while let file = files.nextObject() as? URL {
            let components = file.standardizedFileURL.pathComponents
            let depth = components.count - rootDepth
            // Project folder, session file or session folder, subagents folder, subagent file. Nothing deeper matters.
            if depth >= 4 {
                files.skipDescendants()
            }
            guard file.pathExtension == "jsonl", let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            let stem = file.deletingPathExtension().lastPathComponent
            let key: String
            if depth == 2 {
                key = components[rootDepth]
            } else if depth == 4, components[components.count - 2] == "subagents", stem.hasPrefix("agent-") {
                key = stem
            } else {
                continue
            }
            if latest[key].map({ $0 < modified }) ?? true {
                latest[key] = modified
            }
        }
        return latest
    }

    /// Whether a process runs Claude Code or Codex, from its executable. Claude Code's native binary is
    /// stored under its version number, like `~/.local/share/claude/versions/2.1.318`, so the process
    /// name is the version, not "claude".
    static func isAgent(executable path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("claude") || name.hasPrefix("codex") || path.contains("/claude/versions/")
    }

    /// Current directories of running Claude Code and Codex processes.
    static func agentProcessFolders() -> [String] {
        processFolders().filter { isAgent(executable: $0.executable) }.map(\.folder)
    }

    /// A running process and the folder it works in.
    struct ProcessFolder: Sendable {
        var pid: pid_t
        var executable: String
        var folder: String

        /// What a person would call the process: Claude Code's binary is named after its version.
        var name: String {
            executable.contains("/claude/versions/") ? "claude" : (executable as NSString).lastPathComponent
        }
    }

    /// Background helpers that keep the current directory of the shell that first started them,
    /// for days, without working there. OrbStack started from a terminal in a worktree is one.
    static let helpersWithInheritedFolder: Set<String> = [
        "OrbStack Helper", "OrbStack", "com.docker.backend", "com.docker.build", "Docker Desktop",
    ]

    /// The current directory of every process this user can read, this one and background helpers
    /// left out. A dev server, an editor or a shell sitting in a folder leaves no other trace that
    /// the folder is in use.
    static func processFolders() -> [ProcessFolder] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        let own = getpid()
        var folders: [ProcessFolder] = []
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != own {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let folder = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard !folder.isEmpty else { continue }
            let executable = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
            let process = ProcessFolder(pid: pid, executable: executable, folder: folder)
            if !helpersWithInheritedFolder.contains(process.name) {
                folders.append(process)
            }
        }
        return folders
    }

    /// A process working in `path` or below it, if any.
    static func process(workingIn path: String) -> ProcessFolder? {
        let real = realPath(path)
        return processFolders().first { $0.folder == real || $0.folder.hasPrefix(real + "/") }
    }

    /// For the check right before a worktree is deleted.
    static func isWorking(in path: String) -> Bool {
        AgentActivity().states(of: [path])[path]?.isWorking ?? false
    }
}
