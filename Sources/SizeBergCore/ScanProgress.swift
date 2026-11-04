import Foundation

/// What a running scan knows so far. Numbers only grow while files are read; the final report replaces them.
public struct ScanProgress: Sendable {
    public enum Phase: String, Sendable {
        case discovering = "Finding folders"
        case reading = "Reading files"
        case matching = "Matching shared files"
        case saving = "Saving"
    }

    public struct Group: Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var kind: GroupKind
        public var path: String
        public var fileCount: Int
        /// What du would count so far.
        public var apparentBytes: Int64
        /// Files that share no blocks with anything. Deleting the group frees at least this much.
        public var confirmedFreeableBytes: Int64
        /// What deleting the group alone frees, set once every folder of the group is read.
        public var finalFreeableBytes: Int64?
        public var foldersLeft: Int
        public var foldersTotal: Int

        public var isDone: Bool {
            foldersLeft == 0
        }

        public var isFinal: Bool {
            finalFreeableBytes != nil
        }

        /// The final number when there is one, else what is certain so far.
        public var knownFreeableBytes: Int64 {
            finalFreeableBytes ?? confirmedFreeableBytes
        }

        public var isStarted: Bool {
            foldersLeft < foldersTotal || fileCount > 0
        }
    }

    public var phase: Phase
    public var startedAt: Date
    public var filesRead: Int
    /// From the last scan's cache, or an estimate on a first scan. Nil when unknown.
    public var expectedFiles: Int?
    public var foldersDone: Int
    public var foldersTotal: Int
    public var groups: [Group]

    public var knownFreeableBytes: Int64 {
        groups.reduce(0) { $0 + $1.knownFreeableBytes }
    }

    public var finalGroupCount: Int {
        groups.filter(\.isFinal).count
    }

    /// Share of the expected files read, capped below 1 because the expectation is only an estimate.
    public var fractionRead: Double? {
        guard let expectedFiles, expectedFiles > 0 else { return nil }
        return min(Double(filesRead) / Double(expectedFiles), 0.99)
    }

    /// Projects the elapsed time onto the files still expected. Nil until enough is read to tell.
    public func secondsLeft(now: Date = Date()) -> Double? {
        guard phase == .reading, let fraction = fractionRead, fraction > 0.05 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed / fraction - elapsed
    }
}
