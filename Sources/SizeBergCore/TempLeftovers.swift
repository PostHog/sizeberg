import Darwin
import Foundation

/// What tools leave in the temp folders (`/private/tmp` and `$TMPDIR`) and in `~/.cache`.
///
/// - A leftover is a temp folder with a generated name, like Python's `tmpk3x_9a1b` or mktemp's
///   `tmp.Ab12Cd34`. A run that is killed or crashes never removes it. Leftovers with the same name
///   prefix come from the same tool, so they make one item.
/// - A tool cache is a folder marked with `CACHEDIR.TAG`, the marker Cargo writes into every target
///   folder. A tool that gives each run a target folder of its own fills the disk with them.
/// - Everything else of this user in the temp folders is shown for its size only.
///
/// A folder stays when a process works in it or has a file open there, when it or a file directly
/// in it changed within `quietTime`, or when it holds a socket, which belongs to a running service.
/// Delete also keeps a folder that holds git data.
struct TempLeftovers {
    static let quietTime: TimeInterval = 6 * 60 * 60

    struct Leftover: Equatable {
        var prefix: String
        var paths: [String]
    }

    struct ToolCache: Equatable {
        var path: String
        /// The process that uses it, like "pid 123, cargo".
        var holder: String?
        var isQuiet: Bool

        var canDelete: Bool { isQuiet && holder == nil }
    }

    struct Found: Equatable {
        var leftovers: [Leftover] = []
        var toolCaches: [ToolCache] = []
        /// Folders of this user in each temp root that are neither, keyed by root.
        var other: [String: [String]] = [:]
    }

    let tempRoots: [String]
    let cacheRoot: String
    let now: Date

    init(tempRoots: [String] = ["/private/tmp", realPath(NSTemporaryDirectory())],
         cacheRoot: String = NSHomeDirectory() + "/.cache",
         now: Date = Date()) {
        // TMPDIR can be /tmp itself, or a folder inside it. A root inside another one is covered by it.
        let resolved = tempRoots.map(realPath).reduce(into: [String]()) { roots, root in
            if !roots.contains(root) { roots.append(root) }
        }
        self.tempRoots = resolved.filter { root in !resolved.contains { root.hasPrefix($0 + "/") } }
        self.cacheRoot = realPath(cacheRoot)
        self.now = now
    }

    var roots: [String] { tempRoots + [cacheRoot] }

    /// `claimed` are folders other items measure already, like the uv cache, and `inUse` comes from
    /// `AgentActivity.pathsInUse`.
    func find(claimed: [String], inUse: [AgentActivity.ProcessFolder]) -> Found {
        var found = Found()
        var leftovers: [String: [String]] = [:]
        let isClaimed = { (path: String) in
            claimed.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        for root in roots {
            let isTemp = root != cacheRoot
            for name in Self.children(of: root) {
                let path = root + "/" + name
                guard Self.isOwnFolder(path), !isClaimed(path), name != "claude-\(getuid())" else { continue }
                let holder = Self.holder(of: path, in: inUse)
                let quiet = isQuiet(path)
                if FileManager.default.fileExists(atPath: path + "/CACHEDIR.TAG") {
                    found.toolCaches.append(ToolCache(path: path, holder: holder, isQuiet: quiet))
                    continue
                }
                guard isTemp else { continue }
                // Git data is checked right before deleting, in `reasonToSkip`: the check reads the whole folder.
                if let prefix = Self.generatedPrefix(name), holder == nil, quiet, !Self.holdsSocket(path) {
                    leftovers[prefix, default: []].append(path)
                } else {
                    found.other[root, default: []].append(path)
                }
            }
        }
        found.leftovers = leftovers.map { Leftover(prefix: $0.key, paths: $0.value) }
            .sorted { ($0.paths.count, $1.prefix) > ($1.paths.count, $0.prefix) }
        return found
    }

    /// The fixed part of a generated folder name, or nil when the name does not look generated.
    static func generatedPrefix(_ name: String) -> String? {
        // Python's tempfile: the prefix, then 8 characters from a-z, 0-9 and _. A suffix of letters only
        // reads like a word and one of digits only like a date, so both a letter and a digit or _ are required.
        let pythonCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_")
        if name.count > 8 {
            let suffix = name.suffix(8)
            let prefix = String(name.dropLast(8))
            let separated = prefix == "tmp" || (prefix.last.map { "-_.".contains($0) } ?? false)
            if separated, suffix.allSatisfy(pythonCharacters.contains), suffix.contains(where: \.isLetter), suffix.contains(where: { $0.isNumber || $0 == "_" }) {
                return prefix
            }
        }
        // mktemp: the template, a dot, then at least 6 random letters and digits. A template with a
        // dot of its own, like com.vendor.app, belongs to an app that cleans up after itself, and so does
        // the folder macOS makes for a safe save.
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, !name[..<dot].contains("."), name[..<dot] != "TemporaryDirectory" {
            let suffix = name[name.index(after: dot)...]
            let random = suffix.contains(where: \.isNumber) || (suffix.contains(where: \.isUppercase) && suffix.contains(where: \.isLowercase))
            if suffix.count >= 6, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), random {
                return String(name[...dot])
            }
        }
        return nil
    }

    /// Checks the folders again right before they are deleted: the scan may be hours old.
    func reasonToSkip(_ folders: [String]) -> String? {
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0) }
        let inUse = AgentActivity.pathsInUse(under: existing)
        for folder in existing {
            let name = (folder as NSString).lastPathComponent
            guard roots.contains((folder as NSString).deletingLastPathComponent), Self.isOwnFolder(folder) else {
                return "\(name) is not a temp or cache folder of yours."
            }
            if let holder = Self.holder(of: folder, in: inUse) {
                return "A running process uses \(name) (\(holder))."
            }
            if !isQuiet(folder) {
                return "\(name) changed since the scan."
            }
            if holdsGitData(folder) {
                return "\(name) holds a git repository now."
            }
        }
        return nil
    }

    static func holder(of folder: String, in inUse: [AgentActivity.ProcessFolder]) -> String? {
        inUse.first { $0.folder == folder || $0.folder.hasPrefix(folder + "/") }.map { "pid \($0.pid), \($0.name)" }
    }

    /// The folder and the files directly in it, since writing into a subfolder does not change the folder itself.
    private func isQuiet(_ folder: String) -> Bool {
        let entries = [folder] + Self.children(of: folder).map { folder + "/" + $0 }
        return entries.allSatisfy { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return true }
            return now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) >= Self.quietTime
        }
    }

    private static func holdsSocket(_ folder: String) -> Bool {
        children(of: folder).contains { name in
            var info = stat()
            return lstat(folder + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
        }
    }

    /// A real folder, not a symbolic link, owned by this user. The temp folders are shared by every account.
    private static func isOwnFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private static func children(of folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }
}
