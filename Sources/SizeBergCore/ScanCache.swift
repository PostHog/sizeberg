import CryptoKit
import Foundation

/// Per-group walk results from the last scan, so a rescan only walks groups that changed.
/// Totals live in a small JSON state file; the shared-file entries are raw binary, one file per group.
struct ScanCache {
    struct CachedGroup: Codable {
        var device: Int32
        var apparentBytes: [Int64]
        var unsharedBytes: [Int64]
        var fileCounts: [Int]
        var errorCount: Int
        var entryCount: Int
    }

    struct State: Codable {
        var formatVersion: Int
        var eventID: UInt64
        var volumeUUID: String?
        /// Keyed by segment key.
        var segments: [String: CachedGroup]
    }

    /// Bump when the meaning of cached data changes.
    static let formatVersion = 4

    let directory: URL

    init(directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/sizeberg/groups")) {
        self.directory = directory
    }

    private var stateURL: URL {
        directory.appendingPathComponent("state.json")
    }

    private var privateSizesURL: URL {
        directory.appendingPathComponent("private-sizes-v2.bin")
    }

    func loadPrivateSizes() -> [FileKey: KnownPrivateSize] {
        guard let data = try? Data(contentsOf: privateSizesURL) else { return [:] }
        let stride = MemoryLayout<KnownPrivateSize>.stride
        guard data.count % stride == 0 else { return [:] }
        var records = [KnownPrivateSize](
            repeating: KnownPrivateSize(cloneID: 0, inode: 0, privateBytes: 0, blocks: 0, device: 0),
            count: data.count / stride
        )
        records.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        var byKey: [FileKey: KnownPrivateSize] = [:]
        byKey.reserveCapacity(records.count)
        for record in records {
            byKey[record.key] = record
        }
        return byKey
    }

    func savePrivateSizes(_ records: [KnownPrivateSize]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try records.withUnsafeBytes { Data($0) }.write(to: privateSizesURL, options: .atomic)
    }

    /// Everything that decides what a walk of the group sees. A change makes the cache entry miss.
    static func key(for spec: GroupSpec, nestedRoots: Set<String>) -> String {
        let signature = [
            "v\(formatVersion)",
            "stride\(MemoryLayout<SharedEntry>.stride)",
            spec.paths.joined(separator: "\u{1}"),
            nestedRoots.sorted().joined(separator: "\u{1}"),
            "\(spec.classify)",
            "\(spec.defaultKind.rawValue)",
        ].joined(separator: "\u{2}")
        return hash(signature)
    }

    static func key(_ groupKey: String, _ segmentPath: String) -> String {
        hash(groupKey + "\u{2}" + segmentPath)
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.formatVersion == Self.formatVersion else { return nil }
        return state
    }

    func loadScan(key: String, cached: CachedGroup) -> GroupScan? {
        let url = directory.appendingPathComponent("\(key).bin")
        let expectedSize = cached.entryCount * MemoryLayout<SharedEntry>.stride
        guard let data = try? Data(contentsOf: url), data.count == expectedSize else { return nil }
        var entries = [SharedEntry](
            repeating: SharedEntry(cloneID: 0, inode: 0, allocatedBytes: 0, copies: 0, kind: .source),
            count: cached.entryCount
        )
        entries.withUnsafeMutableBytes { _ = data.copyBytes(to: $0) }
        return GroupScan(
            device: cached.device,
            apparentBytes: cached.apparentBytes,
            unsharedBytes: cached.unsharedBytes,
            fileCounts: cached.fileCounts,
            errorCount: cached.errorCount,
            entries: entries
        )
    }

    /// Writes entries only for `freshKeys`; entries of reused groups are already on disk.
    func save(eventID: UInt64, volumeUUID: String?, scans: [String: GroupScan], freshKeys: Set<String>) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var groups: [String: CachedGroup] = [:]
        for (key, scan) in scans {
            if freshKeys.contains(key) {
                let data = scan.entries.withUnsafeBytes { Data($0) }
                try data.write(to: directory.appendingPathComponent("\(key).bin"), options: .atomic)
            }
            groups[key] = CachedGroup(
                device: scan.device,
                apparentBytes: scan.apparentBytes,
                unsharedBytes: scan.unsharedBytes,
                fileCounts: scan.fileCounts,
                errorCount: scan.errorCount,
                entryCount: scan.entries.count
            )
        }
        let state = State(formatVersion: Self.formatVersion, eventID: eventID, volumeUUID: volumeUUID, segments: groups)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        removeOrphans(keeping: Set(groups.keys))
    }

    private func removeOrphans(keeping keys: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".bin") && !keys.contains(String(name.dropLast(4))) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
