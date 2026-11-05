import Darwin
import Foundation

/// Where someone keeps their code, found instead of assumed: a walk of the home folder that stops at
/// the first folder holding a git repository directly, like `~/workspace` or `~/Documents/GitHub`.
/// That folder is scanned as a whole, its repositories with their worktrees and its other folders as
/// items of their own. A repository right in the home folder, like `~/dotfiles`, is an item by itself.
///
/// Spotlight cannot do this: it does not index hidden folders such as `.git`.
public struct CodeFolders: Sendable {
    /// Folders whose direct children are scanned.
    public var roots: [String]
    /// Repositories found directly in the home folder.
    public var repositories: [String]

    /// Deeper than this, a folder is not where someone keeps their code.
    static let maxDepth = 6

    /// Never searched: macOS and app data, media, and trees that hold dependencies rather than projects.
    /// Hidden folders are skipped too; worktrees in them, like `.claude/worktrees`, come from their repository.
    static let skippedNames: Set<String> = [
        "Library", "Applications", "Pictures", "Music", "Movies", "Public",
        "node_modules", "venv", "Pods", "DerivedData", "target", "dist", "build",
    ]

    public static func find(home: String = NSHomeDirectory()) -> CodeFolders {
        let top = subfolders(of: home)
        let found = Locked(CodeFolders(roots: [], repositories: []))
        DispatchQueue.concurrentPerform(iterations: top.count) { index in
            let folder = top[index]
            if isRepository(folder) {
                found.withLock { $0.repositories.append(folder) }
                return
            }
            let roots = search(folder, depth: 1)
            found.withLock { $0.roots += roots }
        }
        var result = found.withLock { $0 }
        result.roots.sort()
        result.repositories.sort()
        return result
    }

    /// The code folders at or below `folder`. Stops at the first one on each path.
    private static func search(_ folder: String, depth: Int) -> [String] {
        let children = subfolders(of: folder)
        if children.contains(where: isRepository) {
            return [folder]
        }
        guard depth < maxDepth else { return [] }
        return children.flatMap { search($0, depth: depth + 1) }
    }

    /// A folder with a `.git` folder, or a `.git` file, which a worktree or submodule has. Their
    /// parent is a code folder either way; worktrees then come from their repository's list.
    static func isRepository(_ folder: String) -> Bool {
        var info = stat()
        return lstat(folder + "/.git", &info) == 0
    }

    /// Visible subfolders, without following symbolic links or crossing onto another volume.
    private static func subfolders(of folder: String) -> [String] {
        guard let directory = opendir(folder) else { return [] }
        defer { closedir(directory) }
        var parent = stat()
        guard lstat(folder, &parent) == 0 else { return [] }
        var folders: [String] = []
        while let entry = readdir(directory) {
            guard entry.pointee.d_type == DT_DIR else { continue }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard !name.hasPrefix("."), !skippedNames.contains(name) else { continue }
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, info.st_dev == parent.st_dev else { continue }
            folders.append(path)
        }
        return folders
    }
}
