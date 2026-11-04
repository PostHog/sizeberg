import Darwin
import Foundation

/// A cacheable slice of a group: one top-level folder, or the files directly in the group root.
/// FSEvents changes map to segments, so a rescan walks only the folders that changed.
struct Segment {
    var group: Int
    var path: String
    /// Bucket of the folder itself. A group root takes the group default: its own name
    /// says nothing (a cache group may be called ".cache").
    var kind: BucketKind
    /// True for the group root: only its files, because each subfolder is a segment of its own.
    var filesOnly: Bool
    var key: String
}

struct WalkUnit {
    var path: String
    var group: Int
    var segment: Int
    var kind: BucketKind
    var filesOnly: Bool
}

/// Work queue that walker threads also push into, to split big directories while others idle.
/// Dependency trees wait in a lane of their own: on a developer machine they hold about half the files
/// but little of what deleting can free, so everything else is read first and its numbers show early.
final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var firstLane: [WalkUnit] = []
    private var dependencyLane: [WalkUnit] = []
    private var active = 0
    /// Units queued or running per segment. A segment is done when its count drops to zero.
    private var unitsLeft: [Int: Int] = [:]
    private let splitBelow: Int

    init(units: [WalkUnit], workerCount: Int) {
        splitBelow = workerCount * 2
        for unit in units.reversed() {
            add(unit)
        }
    }

    func next() -> WalkUnit? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let unit = firstLane.popLast() ?? dependencyLane.popLast() {
                active += 1
                return unit
            }
            if active == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    /// Returns true when this finished the unit's segment.
    func finish(_ unit: WalkUnit) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        active -= 1
        let left = (unitsLeft[unit.segment] ?? 1) - 1
        unitsLeft[unit.segment] = left == 0 ? nil : left
        condition.broadcast()
        return left == 0
    }

    /// Queues a dependency tree found while reading something else. It always waits for the second lane.
    func deferDependencies(_ unit: WalkUnit) {
        condition.lock()
        add(unit)
        condition.signal()
        condition.unlock()
    }

    /// Hands a subtree to another thread when the current lane runs low. Returns false to keep it.
    func offer(_ unit: WalkUnit) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let isDependency = unit.kind == .dependencies
        let wanted = isDependency
            ? firstLane.isEmpty && dependencyLane.count < splitBelow
            : firstLane.count < splitBelow
        guard wanted else { return false }
        add(unit)
        condition.signal()
        return true
    }

    private func add(_ unit: WalkUnit) {
        if unit.kind == .dependencies {
            dependencyLane.append(unit)
        } else {
            firstLane.append(unit)
        }
        unitsLeft[unit.segment, default: 0] += 1
    }
}

struct WalkGroup {
    var paths: [String]
    var classify: Bool
    var defaultKind: BucketKind
    /// Roots of other groups inside this one. The walk skips them.
    var nestedRoots: Set<String>
}

/// A file that may share blocks with others: an APFS clone, or a hard link.
/// Kept compact (24 bytes) because a developer machine has millions of them.
struct SharedEntry {
    static let blockSize: Int64 = 4096
    static let hardLinkFlag: UInt8 = 0x1
    /// A hard-linked file whose data is also cloned elsewhere. Its blocks never count as freeable.
    static let clonedElsewhereFlag: UInt8 = 0x2

    /// Zero for a hard link.
    var cloneID: UInt64
    var inode: UInt64
    /// Allocated size in 4 KiB blocks, the APFS block size.
    var blocks: UInt32
    /// Link count for a hard link; full clones of the data for a clone, zero when unknown.
    /// Saturates at UInt16.max, which then reads as "copies outside the scan".
    var copies: UInt16
    var flags: UInt8
    var kind: UInt8

    init(cloneID: UInt64, inode: UInt64, allocatedBytes: Int64, copies: UInt32, flags: UInt8 = 0, kind: BucketKind) {
        self.cloneID = cloneID
        self.inode = inode
        blocks = UInt32(clamping: (allocatedBytes + Self.blockSize - 1) / Self.blockSize)
        self.copies = UInt16(clamping: copies)
        self.flags = flags
        self.kind = UInt8(kind.rawValue)
    }

    var allocatedBytes: Int64 {
        Int64(blocks) * Self.blockSize
    }

    var isHardLink: Bool {
        flags & Self.hardLinkFlag != 0
    }

    var isClonedElsewhere: Bool {
        flags & Self.clonedElsewhereFlag != 0
    }
}

/// What a walk learns about one group. Cached between scans, so only changed groups are walked again.
struct GroupScan {
    static let kindCount = BucketKind.allCases.count

    var device: Int32 = 0
    /// What du counts: every clone at full size. Hard links are added once, when families are built.
    var apparentBytes = [Int64](repeating: 0, count: kindCount)
    /// Files that share no blocks with anything.
    var unsharedBytes = [Int64](repeating: 0, count: kindCount)
    var fileCounts = [Int](repeating: 0, count: kindCount)
    var errorCount = 0
    var entries: [SharedEntry] = []

    var fileCount: Int {
        fileCounts.reduce(0, +)
    }

    mutating func merge(_ other: GroupScan) {
        if device == 0 {
            device = other.device
        }
        for kind in 0..<Self.kindCount {
            apparentBytes[kind] += other.apparentBytes[kind]
            unsharedBytes[kind] += other.unsharedBytes[kind]
            fileCounts[kind] += other.fileCounts[kind]
        }
        errorCount += other.errorCount
        entries += other.entries
    }
}

/// Running totals while the walk goes on, per group. `confirmedFreeableBytes` counts files that share
/// no blocks with anything: deleting the group frees them for sure, whatever the shared files turn out to be.
struct WalkProgress {
    var filesRead = 0
    var segmentsDone = 0
    var apparentBytes: [Int64]
    var confirmedFreeableBytes: [Int64]
    var fileCounts: [Int]
    var segmentsLeft: [Int]

    init(groupCount: Int) {
        apparentBytes = Array(repeating: 0, count: groupCount)
        confirmedFreeableBytes = Array(repeating: 0, count: groupCount)
        fileCounts = Array(repeating: 0, count: groupCount)
        segmentsLeft = Array(repeating: 0, count: groupCount)
    }
}

final class Walker: @unchecked Sendable {
    static let progressStep = 25_000
    private static let progressInterval: TimeInterval = 0.25

    let groups: [WalkGroup]
    private let progress: (@Sendable (WalkProgress) -> Void)?
    private let live: Locked<WalkProgress>
    private let lastReport = Locked(Date.distantPast)
    private let startedAt = Date()
    /// Seconds since the walk started at which each segment finished, for `SIZEBERG_TRACE`.
    let segmentFinishTimes = Locked([Int: Double]())

    /// `initial` holds the totals of segments that need no walk, such as cached ones.
    init(groups: [WalkGroup], initial: WalkProgress, progress: (@Sendable (WalkProgress) -> Void)?) {
        self.groups = groups
        self.progress = progress
        live = Locked(initial)
    }

    /// Walks the segments at the given indices and returns one scan per segment index.
    func run(_ segments: [Segment], indices: [Int]) -> [Int: GroupScan] {
        let units = indices.map { index in
            let segment = segments[index]
            return WalkUnit(path: segment.path, group: segment.group, segment: index, kind: segment.kind, filesOnly: segment.filesOnly)
        }
        guard !units.isEmpty else { return [:] }
        Self.raiseOpenFileLimit()
        let workerCount = Self.workerCount()
        let queue = WorkQueue(units: units, workerCount: workerCount)
        let workers = (0..<workerCount).map { _ in WalkWorker(walker: self, queue: queue) }
        DispatchQueue.concurrentPerform(iterations: workerCount) { index in
            workers[index].drain()
        }
        var scans: [Int: GroupScan] = [:]
        for index in indices {
            scans[index] = GroupScan()
        }
        for worker in workers {
            for (index, scan) in worker.scans {
                scans[index, default: GroupScan()].merge(scan)
            }
        }
        return scans
    }

    /// Threads mostly wait in the kernel for metadata, so more threads than performance cores help,
    /// up to a point where APFS lock contention takes over. Measured on an M-series Mac with 18M files:
    /// 4 threads 111 s, 6 threads 81-89 s, 8 threads 79 s, 12 threads 83 s.
    private static func workerCount() -> Int {
        min(8, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Each thread keeps one descriptor open per directory level, and node_modules nest deep.
    private static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        limit.rlim_cur = min(limit.rlim_max, 10_240)
        setrlimit(RLIMIT_NOFILE, &limit)
    }

    func noteFinished(segment: Int) {
        let elapsed = Date().timeIntervalSince(startedAt)
        segmentFinishTimes.withLock { $0[segment] = elapsed }
    }

    /// Adds a worker's totals since its last report. Calls `progress` a few times per second at most.
    func report(_ delta: WorkerTally, finishedSegmentOf finishedGroup: Int?) {
        live.withLock { value in
            value.filesRead += delta.files
            if delta.group >= 0 {
                value.apparentBytes[delta.group] += delta.apparentBytes
                value.confirmedFreeableBytes[delta.group] += delta.confirmedFreeableBytes
                value.fileCounts[delta.group] += delta.files
            }
            if let finishedGroup {
                value.segmentsDone += 1
                value.segmentsLeft[finishedGroup] -= 1
            }
        }
        guard let progress else { return }
        let now = Date()
        // Taking the snapshot and calling back under one lock keeps updates in order.
        lastReport.withLock { last in
            guard finishedGroup != nil || now.timeIntervalSince(last) >= Self.progressInterval else { return }
            last = now
            progress(live.withLock { $0 })
        }
    }
}

/// What one worker read since it last reported, for one group.
struct WorkerTally {
    var group = -1
    var files = 0
    var apparentBytes: Int64 = 0
    var confirmedFreeableBytes: Int64 = 0
}

final class WalkWorker {
    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW

    private let walker: Walker
    private let queue: WorkQueue
    private let reader = BulkReader()

    private(set) var scans: [Int: GroupScan] = [:]
    private var tally = WorkerTally()

    init(walker: Walker, queue: WorkQueue) {
        self.walker = walker
        self.queue = queue
    }

    func drain() {
        while let unit = queue.next() {
            var scan = scans.removeValue(forKey: unit.segment) ?? GroupScan()
            tally = WorkerTally(group: unit.group)
            walk(unit, into: &scan)
            scans[unit.segment] = scan
            let segmentDone = queue.finish(unit)
            if segmentDone {
                walker.noteFinished(segment: unit.segment)
            }
            walker.report(tally, finishedSegmentOf: segmentDone ? unit.group : nil)
            tally = WorkerTally(group: unit.group)
        }
    }

    private func walk(_ unit: WalkUnit, into scan: inout GroupScan) {
        let fd = open(unit.path, Self.openFlags)
        guard fd >= 0 else {
            scan.errorCount += 1
            return
        }
        var info = stat()
        fstat(fd, &info)
        scan.device = info.st_dev
        walkDirectory(fd: fd, path: unit.path, kind: unit.kind, unit: unit, filesOnly: unit.filesOnly, into: &scan)
    }

    /// Reads a whole directory first, then descends, so one read buffer per thread is enough.
    /// Takes ownership of `fd`.
    private func walkDirectory(
        fd: Int32,
        path: String,
        kind: BucketKind,
        unit: WalkUnit,
        filesOnly: Bool,
        into scan: inout GroupScan
    ) {
        defer { close(fd) }
        let settings = walker.groups[unit.group]
        let device = scan.device
        var subdirectories: [String] = []
        let complete = reader.read(directory: fd) { entry in
            switch entry.type {
            case BulkReader.directory:
                // Stay on one volume, like du -x.
                if entry.device == device, let name = entry.name {
                    subdirectories.append(name)
                }
            case BulkReader.regularFile:
                visitFile(entry, kind: kind, into: &scan)
            default:
                scan.apparentBytes[kind.rawValue] += entry.allocatedBytes
                scan.unsharedBytes[kind.rawValue] += entry.allocatedBytes
                tally.apparentBytes += entry.allocatedBytes
                tally.confirmedFreeableBytes += entry.allocatedBytes
            }
        }
        if !complete {
            scan.errorCount += 1
        }
        guard !filesOnly else { return }

        for name in subdirectories {
            let childPath = path + "/" + name
            if !settings.nestedRoots.isEmpty, settings.nestedRoots.contains(childPath) {
                continue
            }
            let childKind = settings.classify
                ? Classifier.kind(forDirectory: name, parent: kind, path: childPath)
                : settings.defaultKind
            let child = WalkUnit(path: childPath, group: unit.group, segment: unit.segment, kind: childKind, filesOnly: false)
            if childKind == .dependencies, kind != .dependencies {
                queue.deferDependencies(child)
                continue
            }
            // Hand subtrees to idle threads, so one huge folder does not run on a single thread.
            if queue.offer(child) {
                continue
            }
            let childFD = openat(fd, name, Self.openFlags)
            guard childFD >= 0 else {
                scan.errorCount += 1
                continue
            }
            walkDirectory(fd: childFD, path: childPath, kind: childKind, unit: unit, filesOnly: false, into: &scan)
        }
    }

    private func visitFile(_ entry: DirectoryEntry, kind: BucketKind, into scan: inout GroupScan) {
        let allocated = entry.allocatedBytes
        scan.fileCounts[kind.rawValue] += 1
        countProgress()

        let isClone = entry.mayShareBlocks && entry.cloneID != 0
        if entry.linkCount > 1 {
            var flags = SharedEntry.hardLinkFlag
            // A reference count of 1 rules out full clones, but not copies changed after cloning,
            // and hard links skip the private size check. So any cloned hard link counts as shared.
            if isClone {
                flags |= SharedEntry.clonedElsewhereFlag
            }
            scan.entries.append(SharedEntry(
                cloneID: 0,
                inode: entry.inode,
                allocatedBytes: allocated,
                copies: entry.linkCount,
                flags: flags,
                kind: kind
            ))
            return
        }
        scan.apparentBytes[kind.rawValue] += allocated
        tally.apparentBytes += allocated
        guard isClone, allocated > 0 else {
            scan.unsharedBytes[kind.rawValue] += allocated
            tally.confirmedFreeableBytes += allocated
            return
        }
        scan.entries.append(SharedEntry(
            cloneID: entry.cloneID,
            inode: entry.inode,
            allocatedBytes: allocated,
            copies: entry.cloneReferenceCount,
            kind: kind
        ))
    }

    private func countProgress() {
        tally.files += 1
        if tally.files >= Walker.progressStep {
            walker.report(tally, finishedSegmentOf: nil)
            tally = WorkerTally(group: tally.group)
        }
    }
}
