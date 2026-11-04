import Foundation

extension Report {
    public static var cacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/sizeberg/last-scan.json")
    }

    public static func loadCached() -> Report? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decoder.decode(Report.self, from: data)
    }

    /// Removes the last report and the per-folder scan cache, so the next scan starts from nothing.
    /// macOS still holds recently read file metadata in memory, so that scan is faster than one after a restart.
    public static func clearCaches() throws {
        let directory = cacheURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public func saveToCache() throws {
        let url = Report.cacheURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func group(_ id: Int) -> GroupReport? {
        groups.indices.contains(id) && groups[id].id == id ? groups[id] : groups.first { $0.id == id }
    }

    public var walkedGroups: [GroupReport] {
        groups.filter { $0.kind != .system }
    }

    /// The sum `du` would show for every scanned folder.
    public var duTotalBytes: Int64 {
        walkedGroups.reduce(0) { $0 + $1.apparentBytes }
    }

    /// Bytes the scanned folders really occupy, each shared block counted once.
    public var trueTotalBytes: Int64 {
        walkedGroups.reduce(0) { $0 + $1.freeableAloneBytes } + sharedSets.reduce(0) { $0 + $1.bytes }
    }

    /// Shared data that only goes away when every group holding a copy goes.
    public var sharedTogetherBytes: Int64 {
        sharedSets.filter { !$0.groupIDs.contains(Report.outsideGroupID) }.reduce(0) { $0 + $1.bytes }
    }

    /// Shared data with a copy outside the scan (another folder or a local snapshot).
    public var sharedOutsideBytes: Int64 {
        sharedSets.filter { $0.groupIDs.contains(Report.outsideGroupID) }.reduce(0) { $0 + $1.bytes }
    }

    /// What deleting every selected group frees.
    public func freeableBytes(selection: Set<Int>) -> Int64 {
        let alone = groups.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.freeableAloneBytes }
        let together = sharedSets
            .filter { set in set.groupIDs.allSatisfy { selection.contains($0) } }
            .reduce(0) { $0 + $1.bytes }
        return alone + together
    }

    public func apparentBytes(selection: Set<Int>) -> Int64 {
        groups.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.apparentBytes }
    }

    /// Worktrees of the repository whose main checkout is `main`, matched by repository path.
    public func worktrees(of main: GroupReport) -> [GroupReport] {
        guard main.kind == .mainCheckout, let repoPath = main.git?.repoPath else { return [] }
        return groups.filter { $0.kind == .worktree && $0.git?.repoPath == repoPath }
    }

    /// Shared bytes this group holds together with other groups.
    public func sharedWithOthersBytes(_ id: Int) -> Int64 {
        sharedSets.filter { $0.groupIDs.contains(id) }.reduce(0) { $0 + $1.bytes }
    }

    public var packageStoreIDs: Set<Int> {
        Set(groups.filter { $0.kind == .cache && ($0.name.hasPrefix("pnpm store") || $0.name == "uv cache") }.map(\.id))
    }

    /// Stale worktrees without local work, plus the package stores that hold their dependencies.
    public var staleSelection: Set<Int> {
        let stale = groups.filter { $0.git?.status == .stale || $0.git?.status == .missing }.map(\.id)
        return Set(stale).union(packageStoreIDs)
    }

    public func label(for set: SharedSet) -> String {
        var names: [String] = []
        var worktrees = 0
        var folders = 0
        var outside = false
        for id in set.groupIDs {
            guard id != Report.outsideGroupID else {
                outside = true
                continue
            }
            guard let group = group(id) else { continue }
            switch group.kind {
            case .worktree, .mainCheckout: worktrees += 1
            case .project: folders += 1
            case .cache, .system: names.append(group.name)
            }
        }
        if worktrees == 1, let only = set.groupIDs.compactMap({ group($0) }).first(where: { $0.kind == .worktree || $0.kind == .mainCheckout }) {
            names.append(only.name)
        } else if worktrees > 1 {
            names.append("\(worktrees) checkouts")
        }
        if folders == 1, let only = set.groupIDs.compactMap({ group($0) }).first(where: { $0.kind == .project }) {
            names.append(only.name)
        } else if folders > 1 {
            names.append("\(folders) folders")
        }
        if outside {
            names.append("outside the scan")
        }
        return names.joined(separator: " + ")
    }

    /// Shell commands for the selection: worktrees first, so a store prune afterwards can drop their packages.
    public func cleanupPlan(selection: Set<Int>) -> String {
        let selected = groups.filter { selection.contains($0.id) }
        var lines = ["# SizeBerg cleanup plan: frees about \(ByteFormat.string(freeableBytes(selection: selection)))"]
        let sections: [(String, [GroupKind])] = [
            ("Worktrees (git refuses to remove one with uncommitted changes)", [.worktree]),
            ("Folders: check each one before you delete it", [.project]),
            ("Caches: run these after the worktrees are gone", [.cache]),
        ]
        for (title, kinds) in sections {
            let commands = selected.filter { kinds.contains($0.kind) }.compactMap(\.cleanupCommand)
            guard !commands.isEmpty else { continue }
            lines.append("")
            lines.append("# \(title)")
            var seen = Set<String>()
            lines += commands.filter { seen.insert($0).inserted }
        }
        return lines.joined(separator: "\n")
    }
}

extension GitInfo {
    /// Merged into the default branch, or the remote branch is gone: the work landed somewhere.
    public var workIsFinished: Bool {
        mergedIntoDefault == true || upstreamGone
    }

    /// Uncommitted changes, or commits no remote has that the default branch does not hold either.
    /// Deleting the worktree would lose them.
    public var hasLocalWork: Bool {
        hasUncommittedChanges == true || (hasUnpushedCommits == true && mergedIntoDefault != true)
    }
}

extension GroupReport {
    /// Quiet worktree without local work: safe to propose for deletion.
    public var isStale: Bool {
        git?.status == .stale
    }
}
