import Foundation

public final class Scanner {
    private let roots: [String]
    /// Repositories scanned as items by themselves, outside any root.
    private let repositories: [String]
    private let fullScan: Bool
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private let cache = ScanCache()
    private let isDebugging = ProcessInfo.processInfo.environment["SIZEBERG_DEBUG"] != nil

    /// `fullScan` ignores the cache and walks everything.
    /// `progress` gets running totals a few times per second, from walker threads.
    /// Without `roots`, the scan looks for the folders that hold git repositories in the home folder.
    public init(roots: [String]? = nil, fullScan: Bool = false, progress: (@Sendable (ScanProgress) -> Void)? = nil) {
        if let roots {
            self.roots = roots
            repositories = []
        } else {
            let found = CodeFolders.find()
            self.roots = found.roots
            repositories = found.repositories
        }
        self.fullScan = fullScan
        self.progress = progress
    }

    public func run() -> Report {
        let start = Date()
        let home = NSHomeDirectory()
        // Reading a directory updates its access time when that is older than its change time.
        // On a first scan that is a metadata write for most folders, so turn it off for this process.
        setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF)
        // Taken before the walk, so changes made while it runs show up in the next scan.
        let eventID = ChangeLog.currentEventID()
        let volumeUUID = ChangeLog.volumeUUID(for: home)
        progress?(ScanProgress(
            phase: .discovering, startedAt: start, filesRead: 0, expectedFiles: nil, foldersDone: 0, foldersTotal: 0, groups: []
        ))
        let dockerUsage = Background { Discovery.dockerUsage() }
        let git = GitInspector()
        let specs = Discovery(roots: roots, repositories: repositories, home: home, git: git).discover()
        let nestedRoots = Self.nestedRoots(specs)
        let walkGroups = specs.indices.map { index in
            WalkGroup(
                paths: specs[index].paths,
                classify: specs[index].classify,
                defaultKind: specs[index].defaultKind,
                nestedRoots: nestedRoots[index]
            )
        }
        let state = cache.loadState()
        let previousGit = previousGitInfos(specs, state: state)
        let gitInfos = Background { () -> [Int: GitInfo] in
            let started = Date()
            let infos = Self.inspect(specs, git: git, previous: previousGit.all, unchanged: previousGit.unchanged)
            if ProcessInfo.processInfo.environment["SIZEBERG_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "git %.1f s\n", Date().timeIntervalSince(started)).utf8))
            }
            return infos
        }
        let segments = Self.segments(specs: specs, nestedRoots: nestedRoots)
        let discovered = Date()

        var segmentScans = reuseCachedScans(segments, state: state, volumeUUID: volumeUUID)
        let toWalk = segments.indices.filter { segmentScans[$0] == nil }
        // Copy counts in reused segments go stale when a copy elsewhere is deleted or changed:
        // nothing in their own folders changes, so FSEvents says nothing. Ask APFS again for those files.
        let departed = segmentScans.isEmpty ? [] : departedSharedFiles(walking: toWalk, segments: segments, state: state)
        let recount = segmentScans.isEmpty ? (segments: [], changed: []) : Self.refreshCopyCounts(in: &segmentScans, sharedWith: departed)
        if isDebugging {
            FileHandle.standardError.write(Data("copy counts: \(departed.count) departed shared files, \(recount.changed.count) changed in \(recount.segments.count) reused segments\n".utf8))
        }
        let reusedAt = Date()
        debugMemory("cache loaded")
        let reporter = ProgressReporter(
            specs: specs,
            segments: segments,
            startedAt: start,
            expectedFiles: Self.expectedFileCount(segments, state: state),
            progress: progress
        )
        var walkProgress: (@Sendable (WalkProgress) -> Void)?
        if progress != nil {
            walkProgress = { reporter.reading($0) }
        }
        let finisher = GroupFinisher(reporter: reporter)
        var onGroupRead: (@Sendable (Int, [GroupScan]) -> Void)?
        if progress != nil {
            // Only each group's own cached scans travel with the closure, not the whole dictionary.
            var cachedByGroup: [Int: [GroupScan]] = [:]
            for (index, scan) in segmentScans {
                cachedByGroup[segments[index].group, default: []].append(scan)
            }
            let cached = cachedByGroup
            onGroupRead = { group, walkedParts in
                finisher.add(group: group, parts: (cached[group] ?? []) + walkedParts)
            }
        }
        let walker = Walker(
            groups: walkGroups, initial: reporter.settle(from: segmentScans), progress: walkProgress, onGroupRead: onGroupRead
        )
        for (index, scan) in walker.run(segments, indices: toWalk) {
            segmentScans[index] = scan
        }
        let livePrivateSizes = finisher.waitForAll()
        let walked = Date()
        debugMemory("walked")
        if let tracePath = ProcessInfo.processInfo.environment["SIZEBERG_TRACE"] {
            Self.writeTrace(to: tracePath, segments: segments, specs: specs, finishTimes: walker.segmentFinishTimes.withLock { $0 })
        }
        // Throttled updates can miss a worker's last totals; the merged scans are exact.
        _ = reporter.settle(from: segmentScans)
        reporter.phase(.matching)

        let snapshots = Self.localSnapshots()
        // A snapshot holds old blocks, which changes private sizes everywhere. Ask APFS again.
        var knownPrivateSizes = fullScan || !snapshots.isEmpty ? [:] : cache.loadPrivateSizes()
        // A file in a changed folder may have gained or lost sharing without changing size: ask APFS again.
        if !knownPrivateSizes.isEmpty {
            for index in toWalk {
                guard let scan = segmentScans[index] else { continue }
                for entry in scan.entries where !entry.isHardLink {
                    knownPrivateSizes[FileKey(device: scan.device, id: entry.cloneID)] = nil
                }
            }
            for key in recount.changed {
                knownPrivateSizes[key] = nil
            }
        }
        // Asked during this walk, so they are fresh: no need to ask APFS twice.
        for record in livePrivateSizes {
            knownPrivateSizes[record.key] = record
        }
        // The cache only needs the segment scans, so it is saved before they are merged per group.
        saveCache(segments: segments, scans: segmentScans, walked: Set(toWalk + recount.segments), eventID: eventID, volumeUUID: volumeUUID)
        let scans = Self.mergeByGroup(&segmentScans, segments: segments, groupCount: specs.count)
        debugMemory("merged")
        let totals = Aggregator(scans: scans, knownPrivateSizes: knownPrivateSizes, isDebugging: isDebugging).run()
        let aggregated = Date()
        debugMemory("aggregated")
        reporter.phase(.saving)
        try? cache.savePrivateSizes(totals.privateSizes)

        let walkedGroups = Set(toWalk.map { segments[$0].group })
        if isDebugging {
            let message = String(
                format: "discovery %.1f s, cache %.1f s, walk %.1f s (%d of %d segments), aggregate %.1f s, save %.1f s\n",
                discovered.timeIntervalSince(start),
                reusedAt.timeIntervalSince(discovered),
                walked.timeIntervalSince(reusedAt),
                toWalk.count,
                segments.count,
                aggregated.timeIntervalSince(walked),
                Date().timeIntervalSince(aggregated)
            )
            let names = toWalk.prefix(20).map { displayPath(segments[$0].path) }.joined(separator: ", ")
            FileHandle.standardError.write(Data((message + "walked: \(names)\n").utf8))
        }

        var report = ReportBuilder(
            specs: specs,
            scans: scans,
            totals: totals,
            gitInfos: gitInfos.value(),
            dockerUsage: dockerUsage.value()
        ).build(start: start, roots: roots, volume: Self.volume(home), snapshots: snapshots)
        report.walkedGroupCount = walkedGroups.count
        if isDebugging {
            let live = reporter.finalBytes()
            let off = live.filter { group, bytes in report.groups[group].freeableAloneBytes != bytes }
            let worst = off.map { abs(report.groups[$0.key].freeableAloneBytes - $0.value) }.max() ?? 0
            FileHandle.standardError.write(Data("live finals: \(live.count) groups, \(off.count) differ from the report, worst by \(worst) bytes\n".utf8))
        }
        report.changedCloneBytes = totals.changedCloneBytes
        report.changedCloneFiles = totals.changedCloneFiles
        report.reusedGroupCount = scans.indices.filter { scans[$0] != nil && !walkedGroups.contains($0) }.count
        return report
    }

    /// The last report's git answers by worktree path, and which worktrees FSEvents saw no change in since.
    private func previousGitInfos(_ specs: [GroupSpec], state: ScanCache.State?) -> (all: [String: GitInfo], unchanged: Set<String>) {
        let paths = Set(specs.compactMap { $0.gitSeed?.worktreePath })
        guard !fullScan, !paths.isEmpty, let previous = Report.loadCached() else { return ([:], []) }
        var all: [String: GitInfo] = [:]
        for group in previous.groups {
            guard let info = group.git, let path = group.paths.first, paths.contains(path) else { continue }
            all[path] = info
        }
        guard let state, let changes = ChangeLog.changes(since: state.eventID, under: Array(paths)) else { return (all, []) }
        let unchanged = Set(all.keys.filter { path in
            !changes.contains { change in
                change.path == path || change.path.hasPrefix(path + "/")
                    || (change.includesSubdirectories && path.hasPrefix(change.path + "/"))
            }
        })
        return (all, unchanged)
    }

    private static func inspect(_ specs: [GroupSpec], git: GitInspector?, previous: [String: GitInfo], unchanged: Set<String>) -> [Int: GitInfo] {
        guard let git else { return [:] }
        let seeds = specs.enumerated().compactMap { index, spec in spec.gitSeed.map { (index, $0) } }
        let results = Locked([Int: GitInfo]())
        DispatchQueue.concurrentPerform(iterations: seeds.count) { position in
            let (index, seed) = seeds[position]
            let path = seed.worktreePath
            let info = git.inspect(seed, previous: previous[path], unchanged: unchanged.contains(path))
            results.withLock { $0[index] = info }
        }
        return results.withLock { $0 }
    }

    /// Debug output for replaying a scan: when each segment finished, and which group and cache file it is.
    private static func writeTrace(to path: String, segments: [Segment], specs: [GroupSpec], finishTimes: [Int: Double]) {
        var lines = ["seconds\tkey\tgroup\tgroup_name\tgroup_kind\tsegment_kind\tpath"]
        for (index, seconds) in finishTimes.sorted(by: { $0.value < $1.value }) {
            let segment = segments[index]
            let spec = specs[segment.group]
            lines.append([
                String(format: "%.3f", seconds), segment.key, "\(segment.group)", spec.name,
                "\(spec.kind)", "\(segment.kind.rawValue)", segment.path,
            ].joined(separator: "\t"))
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// One segment for the files in each group root, and one per folder directly below it.
    private static func segments(specs: [GroupSpec], nestedRoots: [Set<String>]) -> [Segment] {
        var segments: [Segment] = []
        for (group, spec) in specs.enumerated() where spec.isWalked {
            let groupKey = ScanCache.key(for: spec, nestedRoots: nestedRoots[group])
            for root in spec.paths {
                var rootInfo = stat()
                let rootDevice = lstat(root, &rootInfo) == 0 ? rootInfo.st_dev : -1
                segments.append(Segment(group: group, path: root, kind: spec.defaultKind, filesOnly: true, key: ScanCache.key(groupKey, root)))
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
                for name in names {
                    let path = root + "/" + name
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, !nestedRoots[group].contains(path) else { continue }
                    // Stay on the root's volume, like du -x: clone ids only mean something within one volume.
                    guard info.st_dev == rootDevice else { continue }
                    let kind = spec.classify ? Classifier.kind(forDirectory: name, parent: spec.defaultKind, path: path) : spec.defaultKind
                    segments.append(Segment(group: group, path: path, kind: kind, filesOnly: false, key: ScanCache.key(groupKey, path)))
                }
            }
        }
        return segments
    }

    /// Files the last scan found in these segments, so progress can show a share. Nil before any scan.
    private static func expectedFileCount(_ segments: [Segment], state: ScanCache.State?) -> Int? {
        guard let state else { return nil }
        let count = segments.reduce(0) { total, segment in
            total + (state.segments[segment.key]?.fileCounts.reduce(0, +) ?? 0)
        }
        return count > 0 ? count : nil
    }

    /// Cached scans for segments FSEvents reports no change in. Empty on a full scan or a broken history.
    private func reuseCachedScans(_ segments: [Segment], state: ScanCache.State?, volumeUUID: String?) -> [Int: GroupScan] {
        guard !fullScan,
              let state,
              state.volumeUUID != nil,
              state.volumeUUID == volumeUUID else { return [:] }
        let roots = Array(Set(segments.filter(\.filesOnly).map(\.path)))
        guard let changed = ChangeLog.changes(since: state.eventID, under: roots) else { return [:] }
        let changedSegments = Self.segmentsOwning(changed, segments: segments)

        let candidates = segments.indices.filter { !changedSegments.contains($0) && state.segments[segments[$0].key] != nil }
        let reused = Locked([Int: GroupScan]())
        DispatchQueue.concurrentPerform(iterations: candidates.count) { position in
            let index = candidates[position]
            let key = segments[index].key
            guard let cached = state.segments[key], let scan = cache.loadScan(key: key, cached: cached) else { return }
            reused.withLock { $0[index] = scan }
        }
        return reused.withLock { $0 }
    }

    /// Clone ids and hard-linked inodes that the last scan saw in segments that are now walked again
    /// or gone. Copies of these files in reused segments may have lost a sibling.
    private func departedSharedFiles(walking toWalk: [Int], segments: [Segment], state: ScanCache.State?) -> Set<FileKey> {
        guard let state else { return [] }
        let current = Set(segments.map(\.key))
        let keys = toWalk.map { segments[$0].key } + state.segments.keys.filter { !current.contains($0) }
        let departed = Locked(Set<FileKey>())
        DispatchQueue.concurrentPerform(iterations: keys.count) { position in
            let key = keys[position]
            guard let cached = state.segments[key], cached.entryCount > 0, let scan = cache.loadScan(key: key, cached: cached) else { return }
            let found = Set(scan.entries.map { FileKey(device: scan.device, id: $0.isHardLink ? $0.inode : $0.cloneID) })
            departed.withLock { $0.formUnion(found) }
        }
        return departed.withLock { $0 }
    }

    /// Re-reads the copy count of reused entries that may be stale: families that had a member in `departed`,
    /// and every entry that claims to be the only copy (a clone or link made outside the scanned folders
    /// would otherwise make it look private and freeable). Counts going up elsewhere only understate.
    /// Returns the segments whose counts changed, which are saved again, and the files that changed,
    /// whose private sizes are asked again.
    static func refreshCopyCounts(in scans: inout [Int: GroupScan], sharedWith departed: Set<FileKey>) -> (segments: [Int], changed: Set<FileKey>) {
        let indices = Array(scans.keys)
        let updated = Locked([Int: GroupScan]())
        let changedKeys = Locked(Set<FileKey>())
        DispatchQueue.concurrentPerform(iterations: indices.count) { position in
            let index = indices[position]
            guard var scan = scans[index] else { return }
            let probe = FileProbe()
            var changed = Set<FileKey>()
            for offset in scan.entries.indices {
                let entry = scan.entries[offset]
                let key = FileKey(device: scan.device, id: entry.isHardLink ? entry.inode : entry.cloneID)
                let claimsOnlyCopy = entry.copies <= 1 || entry.isHardLink
                guard claimsOnlyCopy || departed.contains(key),
                      let copies = probe.copies(of: entry, device: scan.device),
                      copies != entry.copies else { continue }
                scan.entries[offset].copies = copies
                changed.insert(key)
            }
            guard !changed.isEmpty else { return }
            updated.withLock { $0[index] = scan }
            changedKeys.withLock { $0.formUnion(changed) }
        }
        let refreshed = updated.withLock { $0 }
        for (index, scan) in refreshed {
            scans[index] = scan
        }
        return (Array(refreshed.keys), changedKeys.withLock { $0 })
    }

    /// Maps each change to the deepest segment above it. A change in a group root itself
    /// lands on the root's files-only segment; a new folder there has no cache entry yet anyway.
    /// A change that includes subdirectories also invalidates every segment below its path.
    static func segmentsOwning(_ changes: [ChangeLog.Change], segments: [Segment]) -> Set<Int> {
        var segmentByPath: [String: Int] = [:]
        for (index, segment) in segments.enumerated() {
            segmentByPath[segment.path] = index
        }
        var owners = Set<Int>()
        for change in changes {
            if change.includesSubdirectories {
                let prefix = change.path + "/"
                for (index, segment) in segments.enumerated() where segment.path.hasPrefix(prefix) {
                    owners.insert(index)
                }
            }
            var current = change.path
            while !current.isEmpty {
                if let owner = segmentByPath[current] {
                    owners.insert(owner)
                    break
                }
                guard let slash = current.lastIndex(of: "/") else { break }
                current = String(current[..<slash])
            }
        }
        return owners
    }

    /// Debug aid for SIZEBERG_DEBUG: the memory footprint at a step of the scan, as Activity Monitor shows it.
    private func debugMemory(_ step: String) {
        guard isDebugging else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return }
        FileHandle.standardError.write(Data("memory \(step): \(info.phys_footprint / 1_000_000) MB\n".utf8))
    }

    /// One scan per group from its segment scans, which it empties as it goes, so every entry is held
    /// once at a time: a rescan holds about ten million of them. Each group's entries get one allocation.
    static func mergeByGroup(_ segmentScans: inout [Int: GroupScan], segments: [Segment], groupCount: Int) -> [GroupScan?] {
        var entryCounts = [Int](repeating: 0, count: groupCount)
        for (index, scan) in segmentScans {
            entryCounts[segments[index].group] += scan.entries.count
        }
        var scans = [GroupScan?](repeating: nil, count: groupCount)
        // Group by group, so only one group's new array exists next to the segment scans not yet merged.
        for index in segmentScans.keys.sorted(by: { (segments[$0].group, $0) < (segments[$1].group, $1) }) {
            guard let scan = segmentScans.removeValue(forKey: index) else { continue }
            let group = segments[index].group
            if scans[group] == nil {
                var first = GroupScan()
                first.entries.reserveCapacity(entryCounts[group])
                scans[group] = first
            }
            scans[group]?.merge(scan)
        }
        return scans
    }

    private func saveCache(segments: [Segment], scans: [Int: GroupScan], walked: Set<Int>, eventID: UInt64, volumeUUID: String?) {
        var byKey: [String: GroupScan] = [:]
        var fresh = Set<String>()
        for (index, scan) in scans {
            byKey[segments[index].key] = scan
            if walked.contains(index) {
                fresh.insert(segments[index].key)
            }
        }
        do {
            try cache.save(eventID: eventID, volumeUUID: volumeUUID, scans: byKey, freshKeys: fresh)
        } catch {
            FileHandle.standardError.write(Data("Could not save the scan cache: \(error)\n".utf8))
        }
    }

    private static func nestedRoots(_ specs: [GroupSpec]) -> [Set<String>] {
        let allRoots = specs.flatMap(\.paths)
        return specs.map { spec in
            var nested = Set<String>()
            for path in spec.paths {
                for other in allRoots where other.hasPrefix(path + "/") {
                    nested.insert(other)
                }
            }
            return nested
        }
    }

    static func volume(_ path: String) -> VolumeInfo {
        var info = statfs()
        guard statfs(path, &info) == 0 else {
            return VolumeInfo(totalBytes: 0, freeBytes: 0, availableForImportantUsageBytes: nil)
        }
        let blockSize = Int64(info.f_bsize)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return VolumeInfo(
            totalBytes: Int64(info.f_blocks) * blockSize,
            freeBytes: Int64(info.f_bavail) * blockSize,
            availableForImportantUsageBytes: values?.volumeAvailableCapacityForImportantUsage
        )
    }

    /// Local snapshots hold old copies of blocks, so files read as shared and deleting them frees less.
    private static func localSnapshots() -> [String] {
        let result = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10)
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
    }
}

/// Works out the final frees-alone bytes of each group once it is fully read, off the walker threads.
private final class GroupFinisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sizeberg.group-finisher", qos: .utility, attributes: .concurrent)
    private let pending = DispatchGroup()
    private let reporter: ProgressReporter
    private let privateSizes = Locked([KnownPrivateSize]())

    init(reporter: ProgressReporter) {
        self.reporter = reporter
    }

    /// `parts` are the group's segment scans, cached and walked; they are merged here, not on a walker thread.
    func add(group: Int, parts: [GroupScan]) {
        queue.async(group: pending) {
            var scan = GroupScan()
            parts.forEach { scan.merge($0) }
            let result = Aggregator.freeableAlone(of: scan, probe: FileProbe())
            self.privateSizes.withLock { $0 += result.privateSizes }
            self.reporter.finished(group: group, freeableAloneBytes: result.bytes)
        }
    }

    /// Waits for groups still being worked out, then returns every private size asked so far.
    func waitForAll() -> [KnownPrivateSize] {
        pending.wait()
        return privateSizes.withLock { $0 }
    }
}

/// Turns walker totals into `ScanProgress` with group names, from any thread.
private final class ProgressReporter: @unchecked Sendable {
    private let specs: [GroupSpec]
    private let segmentCounts: [Int]
    private let segmentGroups: [Int]
    private let startedAt: Date
    private let expectedFiles: Int?
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private let latest: Locked<WalkProgress>
    /// Final frees-alone bytes of groups that are fully read.
    private let finals = Locked([Int: Int64]())
    /// Walker threads and the group finisher both send updates. One at a time keeps them in order.
    private let emitting = NSLock()

    init(specs: [GroupSpec], segments: [Segment], startedAt: Date, expectedFiles: Int?, progress: (@Sendable (ScanProgress) -> Void)?) {
        self.specs = specs
        var counts = [Int](repeating: 0, count: specs.count)
        for segment in segments {
            counts[segment.group] += 1
        }
        segmentCounts = counts
        segmentGroups = segments.map(\.group)
        self.startedAt = startedAt
        self.expectedFiles = expectedFiles
        self.progress = progress
        latest = Locked(WalkProgress(groupCount: specs.count))
    }

    /// Exact totals from finished segment scans: the cached ones before the walk, all of them after it.
    func settle(from scans: [Int: GroupScan]) -> WalkProgress {
        var value = WalkProgress(groupCount: specs.count)
        value.segmentsLeft = segmentCounts
        for (segment, scan) in scans {
            let group = segmentGroups[segment]
            value.apparentBytes[group] += scan.apparentBytes.reduce(0, +)
            value.confirmedFreeableBytes[group] += scan.unsharedBytes.reduce(0, +)
            value.fileCounts[group] += scan.fileCount
            value.filesRead += scan.fileCount
            value.segmentsLeft[group] -= 1
            value.segmentsDone += 1
        }
        latest.withLock { $0 = value }
        return value
    }

    func reading(_ value: WalkProgress) {
        emitting.withLock {
            latest.withLock { $0 = value }
            emit(.reading, value)
        }
    }

    func finalBytes() -> [Int: Int64] {
        finals.withLock { $0 }
    }

    func finished(group: Int, freeableAloneBytes: Int64) {
        emitting.withLock {
            finals.withLock { $0[group] = freeableAloneBytes }
            emit(.reading, latest.withLock { $0 })
        }
    }

    func phase(_ phase: ScanProgress.Phase) {
        emitting.withLock {
            emit(phase, latest.withLock { $0 })
        }
    }

    private func emit(_ phase: ScanProgress.Phase, _ value: WalkProgress) {
        guard let progress else { return }
        let finals = finals.withLock { $0 }
        let groups = specs.indices.compactMap { index -> ScanProgress.Group? in
            let spec = specs[index]
            guard spec.isWalked else { return nil }
            return ScanProgress.Group(
                id: index,
                name: spec.name,
                kind: spec.kind,
                path: spec.paths.first ?? "",
                fileCount: value.fileCounts[index],
                apparentBytes: value.apparentBytes[index],
                confirmedFreeableBytes: value.confirmedFreeableBytes[index],
                finalFreeableBytes: finals[index],
                foldersLeft: value.segmentsLeft[index],
                foldersTotal: segmentCounts[index]
            )
        }
        progress(ScanProgress(
            phase: phase,
            startedAt: startedAt,
            filesRead: value.filesRead,
            expectedFiles: expectedFiles,
            foldersDone: value.segmentsDone,
            foldersTotal: segmentCounts.reduce(0, +),
            groups: groups
        ))
    }
}

private struct ReportBuilder {
    let specs: [GroupSpec]
    let scans: [GroupScan?]
    let totals: Aggregator.Result
    let gitInfos: [Int: GitInfo]
    let dockerUsage: String?

    /// Build output and cache folders per group, with a kept dependency folder split out of its cache.
    private func buildFolders() -> [Int: [BucketKind: [BuildFolder]]] {
        var byGroup: [Int: [BucketKind: [BuildFolder]]] = [:]
        for (index, scan) in scans.enumerated() {
            guard let scan, !scan.trimFolders.isEmpty else { continue }
            let recorded = scan.trimFolders.map { folder in
                TrimFolder(path: folder.path, kind: folder.kind, bytes: scan.trimFolderBytes[folder.path] ?? 0)
            }
            byGroup[index] = Dictionary(grouping: TrimFolder.excludingDependencies(recorded), by: \.kind).mapValues { found in
                found.map { BuildFolder(path: $0.path, bytes: $0.bytes) }.sorted { $0.path < $1.path }
            }
        }
        return byGroup
    }

    /// Which of the folders big enough to delete hold files git tracks, per checkout or worktree.
    /// In parallel. A checkout git does not answer for is left as is; the cleanup checks again
    /// right before it deletes anything.
    private func trackedFolders(_ folders: [Int: [BucketKind: [BuildFolder]]]) -> [Int: Set<String>] {
        let checkouts = folders.keys.filter { [.mainCheckout, .worktree].contains(specs[$0].kind) }
        let found = Locked([Int: Set<String>]())
        DispatchQueue.concurrentPerform(iterations: checkouts.count) { position in
            let index = checkouts[position]
            let candidates = folders[index, default: [:]].values.joined().filter { $0.bytes >= BuildFolder.smallBytes }.map(\.path)
            guard !candidates.isEmpty,
                  let tracked = CleanupRunner.trackedFolders(in: specs[index].paths[0], among: candidates) else { return }
            found.withLock { $0[index] = tracked }
        }
        return found.withLock { $0 }
    }

    func build(start: Date, roots: [String], volume: VolumeInfo, snapshots: [String]) -> Report {
        let kindsPerGroup = BucketKind.allCases.count
        let allFolders = buildFolders()
        let tracked = trackedFolders(allFolders)
        var groups: [GroupReport] = []
        for (index, spec) in specs.enumerated() {
            if let fixed = spec.fixedBytes {
                groups.append(fixedGroup(index: index, spec: spec, bytes: fixed))
                continue
            }
            var buckets: [BucketReport] = []
            let folders = allFolders[index] ?? [:]
            for kind in BucketKind.allCases {
                let bucket = index * kindsPerGroup + kind.rawValue
                guard totals.apparentBytes[bucket] > 0 || totals.fileCounts[bucket] > 0 else { continue }
                var report = BucketReport(
                    kind: kind,
                    apparentBytes: totals.apparentBytes[bucket],
                    privateBytes: totals.privateBytes[bucket],
                    freeableAloneBytes: totals.freeableAloneBytes[bucket],
                    fileCount: totals.fileCounts[bucket]
                )
                if kind.isTrimmable, let found = folders[kind] {
                    let choice = BuildFolder.choose(found, tracked: tracked[index] ?? [], freeable: report.freeableAloneBytes)
                    report.folders = choice.folders
                    report.foldersFreeBytes = choice.freeBytes
                    report.smallFolderCount = choice.small.count
                    report.smallFolderBytes = choice.small.reduce(0) { $0 + $1.bytes }
                    report.trackedFolderCount = choice.trackedCount
                }
                buckets.append(report)
            }
            let privateBytes = buckets.reduce(0) { $0 + $1.privateBytes }
            groups.append(GroupReport(
                id: index,
                kind: spec.kind,
                name: spec.name,
                paths: spec.paths,
                git: gitInfos[index],
                buckets: buckets,
                apparentBytes: buckets.reduce(0) { $0 + $1.apparentBytes },
                privateBytes: privateBytes,
                freeableAloneBytes: privateBytes + (totals.sets[GroupSet(index)]?.bytes ?? 0),
                selectable: spec.kind != .mainCheckout && !(spec.kind == .project && spec.cleanupCommand == nil),
                cleanupCommand: spec.cleanupCommand,
                note: spec.note
            ))
        }

        // One pass over the agents' transcripts and the process table for every checkout.
        let checkouts = groups.filter { $0.kind == .mainCheckout || $0.kind == .worktree }.map(\.path)
        let agents = AgentActivity().states(of: checkouts)
        for index in groups.indices where groups[index].kind == .mainCheckout || groups[index].kind == .worktree {
            groups[index].agent = agents[groups[index].path]
        }

        let sharedSets = totals.sets
            .filter { $0.key.count > 1 }
            .map { set, value in
                SharedSet(
                    groupIDs: set.members.map { $0 == GroupSet.outsideIndex ? Report.outsideGroupID : $0 },
                    bytes: value.bytes,
                    familyCount: value.families
                )
            }
            .sorted { $0.bytes > $1.bytes }

        return Report(
            scannedAt: Date(),
            durationSeconds: Date().timeIntervalSince(start),
            roots: roots,
            fileCount: scans.reduce(0) { $0 + ($1?.fileCount ?? 0) },
            errorCount: scans.reduce(0) { $0 + ($1?.errorCount ?? 0) },
            volume: volume,
            localSnapshots: snapshots,
            groups: groups,
            sharedSets: sharedSets
        )
    }

    private func fixedGroup(index: Int, spec: GroupSpec, bytes: Int64) -> GroupReport {
        GroupReport(
            id: index,
            kind: spec.kind,
            name: spec.name,
            paths: spec.paths,
            git: gitInfos[index],
            buckets: [],
            apparentBytes: bytes,
            privateBytes: bytes,
            freeableAloneBytes: 0,
            selectable: spec.kind == .worktree,
            cleanupCommand: spec.cleanupCommand,
            note: [spec.note, spec.showsDockerUsage ? dockerUsage : nil].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        )
    }
}

/// Runs work on a background queue and hands back the result when asked.
final class Background<Value>: @unchecked Sendable {
    private let done = DispatchGroup()
    private var result: Value?

    init(_ work: @escaping @Sendable () -> Value) {
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.result = work()
            self.done.leave()
        }
    }

    func value() -> Value {
        done.wait()
        return result!
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
