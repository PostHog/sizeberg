import Foundation

public final class Scanner {
    public static var defaultRoots: [String] {
        [NSHomeDirectory() + "/workspace"]
    }

    private let roots: [String]
    private let fullScan: Bool
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private let cache = ScanCache()
    private let isDebugging = ProcessInfo.processInfo.environment["SIZEBERG_DEBUG"] != nil

    /// `fullScan` ignores the cache and walks everything.
    /// `progress` gets running totals a few times per second, from walker threads.
    public init(roots: [String], fullScan: Bool = false, progress: (@Sendable (ScanProgress) -> Void)? = nil) {
        self.roots = roots
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
        let specs = Discovery(roots: roots, home: home, git: git).discover()
        let nestedRoots = Self.nestedRoots(specs)
        let walkGroups = specs.indices.map { index in
            WalkGroup(
                paths: specs[index].paths,
                classify: specs[index].classify,
                defaultKind: specs[index].defaultKind,
                nestedRoots: nestedRoots[index]
            )
        }
        let gitInfos = Background { () -> [Int: GitInfo] in
            let started = Date()
            let infos = Self.inspect(specs, git: git)
            if ProcessInfo.processInfo.environment["SIZEBERG_DEBUG"] != nil {
                FileHandle.standardError.write(Data(String(format: "git %.1f s\n", Date().timeIntervalSince(started)).utf8))
            }
            return infos
        }
        let segments = Self.segments(specs: specs, nestedRoots: nestedRoots)
        let discovered = Date()

        var segmentScans = reuseCachedScans(segments, volumeUUID: volumeUUID)
        let toWalk = segments.indices.filter { segmentScans[$0] == nil }
        let reusedAt = Date()
        let reporter = ProgressReporter(
            specs: specs,
            segments: segments,
            startedAt: start,
            expectedFiles: expectedFileCount(segments),
            progress: progress
        )
        var walkProgress: (@Sendable (WalkProgress) -> Void)?
        if progress != nil {
            walkProgress = { reporter.reading($0) }
        }
        let walker = Walker(groups: walkGroups, initial: reporter.settle(from: segmentScans), progress: walkProgress)
        for (index, scan) in walker.run(segments, indices: toWalk) {
            segmentScans[index] = scan
        }
        let walked = Date()
        if let tracePath = ProcessInfo.processInfo.environment["SIZEBERG_TRACE"] {
            Self.writeTrace(to: tracePath, segments: segments, specs: specs, finishTimes: walker.segmentFinishTimes.withLock { $0 })
        }
        // Throttled updates can miss a worker's last totals; the merged scans are exact.
        _ = reporter.settle(from: segmentScans)
        reporter.phase(.matching)

        var scans = [GroupScan?](repeating: nil, count: specs.count)
        for (index, scan) in segmentScans {
            let group = segments[index].group
            if scans[group] == nil {
                scans[group] = scan
            } else {
                scans[group]?.merge(scan)
            }
        }
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
        }
        let totals = Aggregator(scans: scans, knownPrivateSizes: knownPrivateSizes, isDebugging: isDebugging).run()
        let aggregated = Date()
        reporter.phase(.saving)
        saveCache(segments: segments, scans: segmentScans, walked: Set(toWalk), eventID: eventID, volumeUUID: volumeUUID)
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
        report.changedCloneBytes = totals.changedCloneBytes
        report.changedCloneFiles = totals.changedCloneFiles
        report.reusedGroupCount = scans.indices.filter { scans[$0] != nil && !walkedGroups.contains($0) }.count
        return report
    }

    private static func inspect(_ specs: [GroupSpec], git: GitInspector?) -> [Int: GitInfo] {
        guard let git else { return [:] }
        let seeds = specs.enumerated().compactMap { index, spec in spec.gitSeed.map { (index, $0) } }
        let results = Locked([Int: GitInfo]())
        DispatchQueue.concurrentPerform(iterations: seeds.count) { position in
            let (index, seed) = seeds[position]
            let info = git.inspect(seed)
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
    private func expectedFileCount(_ segments: [Segment]) -> Int? {
        guard let state = cache.loadState() else { return nil }
        let count = segments.reduce(0) { total, segment in
            total + (state.segments[segment.key]?.fileCounts.reduce(0, +) ?? 0)
        }
        return count > 0 ? count : nil
    }

    /// Cached scans for segments FSEvents reports no change in. Empty on a full scan or a broken history.
    private func reuseCachedScans(_ segments: [Segment], volumeUUID: String?) -> [Int: GroupScan] {
        guard !fullScan,
              let state = cache.loadState(),
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

    private static func volume(_ path: String) -> VolumeInfo {
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

/// Turns walker totals into `ScanProgress` with group names, from any thread.
private final class ProgressReporter: @unchecked Sendable {
    private let specs: [GroupSpec]
    private let segmentCounts: [Int]
    private let segmentGroups: [Int]
    private let startedAt: Date
    private let expectedFiles: Int?
    private let progress: (@Sendable (ScanProgress) -> Void)?
    private let latest: Locked<WalkProgress>

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
        latest.withLock { $0 = value }
        emit(.reading, value)
    }

    func phase(_ phase: ScanProgress.Phase) {
        emit(phase, latest.withLock { $0 })
    }

    private func emit(_ phase: ScanProgress.Phase, _ value: WalkProgress) {
        guard let progress else { return }
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

    func build(start: Date, roots: [String], volume: VolumeInfo, snapshots: [String]) -> Report {
        let kindsPerGroup = BucketKind.allCases.count
        var groups: [GroupReport] = []
        for (index, spec) in specs.enumerated() {
            if let fixed = spec.fixedBytes {
                groups.append(fixedGroup(index: index, spec: spec, bytes: fixed))
                continue
            }
            var buckets: [BucketReport] = []
            for kind in BucketKind.allCases {
                let bucket = index * kindsPerGroup + kind.rawValue
                guard totals.apparentBytes[bucket] > 0 || totals.fileCounts[bucket] > 0 else { continue }
                buckets.append(BucketReport(
                    kind: kind,
                    apparentBytes: totals.apparentBytes[bucket],
                    privateBytes: totals.privateBytes[bucket],
                    freeableAloneBytes: totals.freeableAloneBytes[bucket],
                    fileCount: totals.fileCounts[bucket]
                ))
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
                selectable: spec.kind != .mainCheckout,
                cleanupCommand: spec.cleanupCommand,
                note: spec.note
            ))
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
