import Foundation

/// A file or folder git ignores that deleting a worktree would take with it.
public struct IgnoredFile: Sendable, Equatable {
    /// Relative to the worktree; a folder ends in "/".
    public var path: String
    /// A `.env` file or a key, which may hold a secret that exists nowhere else.
    public var looksSecret: Bool
}

/// `git worktree remove` refuses uncommitted and untracked files, but deletes files git ignores
/// without a word: a `.env`, local settings, notes. This lists the ones that would really be lost.
///
/// Left out: rebuildable data (the names `Classifier` knows, Flox's cache, tool output like `.husky/_`
/// and `.trunk`), and files identical to the main checkout's copy at the same path, which the main
/// checkout keeps. On one machine with 77 worktrees, 37 had a `.env`; 20 of those were such copies.
public enum IgnoredFiles {
    /// Tool output and caches that git ignores and a tool writes again.
    static let rebuildableNames: Set<String> = [".husky", ".trunk", ".import_linter_cache", "out", "generated", ".workers"]
    static let rebuildableSuffixes = [".tsbuildinfo", ".log", "/junit.xml", "/CACHEDIR.TAG"]

    public static func lost(in worktree: String, mainCheckout: String?) -> [IgnoredFile]? {
        guard let git = Shell.find("git") else { return nil }
        let result = Shell.run(git, ["-C", worktree, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], timeout: 60)
        guard result.status == 0, !result.timedOut else { return nil }
        let entries = result.output.split(separator: "\0").map(String.init)
        // --directory names a folder once; drop anything listed inside a folder that is listed too.
        let folders = entries.filter { $0.hasSuffix("/") }
        let top = entries.filter { entry in !folders.contains { $0 != entry && entry.hasPrefix($0) } }
        return top.filter { !isRebuildable($0) && !isCopy($0, of: worktree, in: mainCheckout) }
            .map { IgnoredFile(path: $0, looksSecret: looksSecret($0)) }
    }

    static func isRebuildable(_ path: String) -> Bool {
        if path.hasPrefix(".flox/cache") || path.hasPrefix(".flox/log") || path.hasPrefix(".flox/run") {
            return true
        }
        let parts = path.split(separator: "/").map(String.init)
        let known = Classifier.dependencyNames.union(Classifier.buildNames).union(Classifier.cacheNames).union(rebuildableNames)
        if parts.contains(where: known.contains) || parts.last == "target" {
            return true
        }
        return rebuildableSuffixes.contains { ("/" + path).hasSuffix($0) }
    }

    private static func isCopy(_ path: String, of worktree: String, in mainCheckout: String?) -> Bool {
        guard let mainCheckout, !path.hasSuffix("/") else { return false }
        return FileManager.default.contentsEqual(atPath: worktree + "/" + path, andPath: mainCheckout + "/" + path)
    }

    static func looksSecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".env" || name.hasPrefix(".env.") || [".key", ".pem", ".p12"].contains { name.hasSuffix($0) }
    }
}
