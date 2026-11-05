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
        if id == Report.buildOutputID {
            return buildOutputItem
        }
        return groups.indices.contains(id) && groups[id].id == id ? groups[id] : groups.first { $0.id == id }
    }

    /// The scanned groups, plus the build output item when there is build output to delete.
    public var items: [GroupReport] {
        groups + [buildOutputItem].compactMap { $0 }
    }

    /// Build output and caches of every checkout, worktree and folder, as one item to delete.
    /// The items stay; the next build or tool run puts these folders back.
    public var buildOutputItem: GroupReport? {
        let holders = groups.filter { $0.trimBytes > 0 }
        guard !holders.isEmpty else { return nil }
        let bytes = trimAllBytes
        return GroupReport(
            id: Report.buildOutputID, kind: .buildOutput, name: "Build output and caches", paths: [], git: nil, buckets: [],
            apparentBytes: holders.flatMap(\.trimmableBuckets).reduce(0) { $0 + $1.apparentBytes },
            privateBytes: bytes, freeableAloneBytes: bytes, selectable: true, cleanupCommand: nil,
            note: "The next build or tool run puts these folders back. Dependencies stay, and so do folders that hold files git tracks."
        )
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
    /// The build output item adds only what lies in items the selection keeps: a deleted item frees its build output anyway.
    public func freeableBytes(selection: Set<Int>) -> Int64 {
        let alone = groups.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.freeableAloneBytes }
        let together = sharedSets
            .filter { set in set.groupIDs.allSatisfy { selection.contains($0) } }
            .reduce(0) { $0 + $1.bytes }
        return alone + together + buildOutputBytes(keeping: selection)
    }

    public func apparentBytes(selection: Set<Int>) -> Int64 {
        let trimmed = selection.contains(Report.buildOutputID)
            ? groups.filter { !selection.contains($0.id) }.flatMap(\.trimmableBuckets).reduce(0) { $0 + $1.apparentBytes }
            : 0
        return groups.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.apparentBytes } + trimmed
    }

    private func buildOutputBytes(keeping selection: Set<Int>) -> Int64 {
        guard selection.contains(Report.buildOutputID) else { return 0 }
        return groups.filter { !selection.contains($0.id) }.reduce(0) { $0 + $1.trimBytes }
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
        let stale = groups.filter(\.goesWithStale).map(\.id)
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
            case .cache, .system, .buildOutput: names.append(group.name)
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

    /// Shell commands for the selection, in the order the app runs them.
    public func cleanupPlan(selection: Set<Int>) -> String {
        let steps = CleanupRunner.plan(for: self, selection: selection).steps
        var lines = ["# SizeBerg cleanup plan: frees about \(ByteFormat.string(freeableBytes(selection: selection)))"]
        let sections: [(String, [GroupKind])] = [
            ("Worktrees (git refuses to remove one with uncommitted changes)", [.worktree]),
            ("Folders: check each one before you delete it", [.project]),
            ("Caches: run these after the worktrees are gone", [.cache]),
        ]
        for (title, kinds) in sections {
            let commands = steps.filter { !$0.isTrim && kinds.contains($0.kind) }.map(\.command)
            guard !commands.isEmpty else { continue }
            lines.append("")
            lines.append("# \(title)")
            lines += commands
        }
        let trims = steps.filter(\.isTrim).map(\.command)
        if !trims.isEmpty {
            lines += ["", "# Build output and caches: leave out folders that hold files git tracks"] + trims
        }
        return lines.joined(separator: "\n")
    }

    /// Items a trim cleans: checkouts, worktrees and folders that hold build output or caches.
    public var trimmableIDs: Set<Int> {
        Set(groups.filter { $0.trimBytes > 0 }.map(\.id))
    }

    /// What trimming every item frees. A lower bound: data shared only among trimmed folders
    /// of several items frees too, and is not counted.
    public var trimAllBytes: Int64 {
        groups.reduce(0) { $0 + $1.trimBytes }
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
    /// Build output and caches in an item that can stay: a checkout, a worktree or a folder.
    public var trimmableBuckets: [BucketReport] {
        guard [.mainCheckout, .worktree, .project].contains(kind), git?.status != .missing else { return [] }
        return buckets.filter { $0.kind.isTrimmable && !($0.folders ?? []).isEmpty }
    }

    public var trimBytes: Int64 {
        trimmableBuckets.reduce(0) { $0 + $1.freeableAloneBytes }
    }

    /// What "Select Stale" picks: stale worktrees without local work, and worktrees whose folder is gone.
    public var goesWithStale: Bool {
        git?.status == .stale || git?.status == .missing
    }

    /// Quiet worktree without local work: safe to propose for deletion.
    public var isStale: Bool {
        git?.status == .stale
    }
}
