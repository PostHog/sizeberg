import CoreServices
import Foundation

/// Asks the FSEvents history which directories changed since an earlier event id.
/// macOS keeps this log per volume, so no watcher has to run between scans.
enum ChangeLog {
    /// A directory with changes. `includesSubdirectories` comes from kFSEventStreamEventFlagMustScanSubDirs:
    /// FSEvents coalesced changes below the path, so every folder under it must be read again.
    struct Change {
        var path: String
        var includesSubdirectories: Bool
    }

    private static let historyTimeout: TimeInterval = 30

    private final class Collector {
        var changes: [Change] = []
        var historyIsIncomplete = false
        let done = DispatchSemaphore(value: 0)
    }

    static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Changes when the volume's event store is reset; old event ids then mean nothing.
    static func volumeUUID(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// FSEvents gives up on a stream with thousands of roots, and every scan then reads everything again.
    static let maxRoots = 256

    /// The folders to ask FSEvents about, at most `maxRoots`. Many folders that share a parent, like
    /// thousands of temp folders, are watched through that parent. A change beside them belongs to no
    /// segment, so it costs an event and nothing else.
    static func watchRoots(_ paths: [String]) -> [String] {
        var roots = Set(paths)
        while roots.count > maxRoots {
            let byParent = Dictionary(grouping: roots) { ($0 as NSString).deletingLastPathComponent }
            guard let busiest = byParent.max(by: { $0.value.count < $1.value.count }), busiest.value.count > 1 else { break }
            roots.subtract(busiest.value)
            roots.insert(busiest.key)
        }
        var result: [String] = []
        for root in roots.sorted() where !result.contains(where: { root.hasPrefix($0 + "/") }) {
            result.append(root)
        }
        return result
    }

    /// Directories with changes below `roots` since `eventID`.
    /// Nil when the history is incomplete, so the caller must scan everything.
    static func changes(since eventID: UInt64, under roots: [String]) -> [Change]? {
        guard !roots.isEmpty else { return [] }
        let collector = Collector()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for index in 0..<count {
                let flags = Int(eventFlags[index])
                if flags & kFSEventStreamEventFlagHistoryDone != 0 {
                    collector.done.signal()
                    continue
                }
                let lostEvents = kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
                if flags & lostEvents != 0 {
                    collector.historyIsIncomplete = true
                }
                if let path = paths[index] as? String {
                    let recursive = flags & kFSEventStreamEventFlagMustScanSubDirs != 0
                    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
                    collector.changes.append(Change(path: trimmed, includesSubdirectories: recursive))
                }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, eventID, 0, flags) else {
            return nil
        }
        let queue = DispatchQueue(label: "sizeberg.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        let finished = collector.done.wait(timeout: .now() + historyTimeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return queue.sync {
            guard finished, !collector.historyIsIncomplete else { return nil }
            return collector.changes
        }
    }
}
