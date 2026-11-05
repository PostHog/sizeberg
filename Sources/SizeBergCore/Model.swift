import Foundation

public enum BucketKind: Int, Codable, CaseIterable, Sendable {
    case source
    case dependencies
    case buildOutput
    case caches
    case git

    public var title: String {
        switch self {
        case .source: return "Source and other files"
        case .dependencies: return "Dependencies"
        case .buildOutput: return "Build output"
        case .caches: return "Caches"
        case .git: return "Git data"
        }
    }

    /// What a trim deletes from an item that stays: the next build or tool run puts it back.
    /// Dependencies need an install, and APFS clones make them free little, so a trim leaves them.
    public var isTrimmable: Bool {
        self == .buildOutput || self == .caches
    }
}

public enum GroupKind: String, Codable, Sendable {
    case mainCheckout
    case worktree
    case project
    case cache
    case system
    /// One list item for the build output and caches inside every checkout, worktree and folder.
    /// The report does not store it; `Report.buildOutputItem` derives it from the other groups.
    case buildOutput
}

public enum WorktreeStatus: String, Codable, Sendable {
    case active
    case stale
    case staleWithLocalWork
    case missing
}

public struct GitInfo: Codable, Sendable {
    public var repoPath: String
    public var branch: String?
    public var headDate: Date?
    public var lastActive: Date?
    public var upstreamGone: Bool
    /// The slow checks run only where they can change the status: nil means not checked.
    /// Merge and push state for worktrees quiet for a few days, uncommitted changes for stale ones.
    public var mergedIntoDefault: Bool?
    public var hasUncommittedChanges: Bool?
    public var hasUnpushedCommits: Bool?
    public var status: WorktreeStatus
    /// The commit HEAD pointed at, so a rescan can tell a commit happened without running git status.
    public var headCommit: String? = nil
}

/// A folder of build output or caches that deleting build output removes, with its size on disk.
public struct BuildFolder: Codable, Sendable, Hashable {
    public var path: String
    /// Allocated bytes of its files, as du counts them. Build output and caches share almost
    /// nothing, so this is close to what deleting the folder frees.
    public var bytes: Int64

    public init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
    }

    /// Smaller folders stay. A Python tree has one __pycache__ of about 100 KB per package:
    /// thousands of deletes for little space, and every one makes the next import slower.
    public static let smallBytes: Int64 = 1_000_000

    /// Which folders deleting build output takes, and what that frees.
    struct Choice {
        var folders: [BuildFolder]
        /// The bucket's frees-alone share for the chosen folders.
        var freeBytes: Int64
        var small: [BuildFolder]
        var trackedCount: Int
    }

    /// Leaves out folders git tracks and folders under `smallBytes`. `freeable` is what deleting all
    /// of the bucket frees; the chosen folders get the part their size makes up.
    static func choose(_ all: [BuildFolder], tracked: Set<String>, freeable: Int64) -> Choice {
        let untracked = all.filter { !tracked.contains($0.path) }
        let chosen = untracked.filter { $0.bytes >= smallBytes }
        let allBytes = all.reduce(0) { $0 + $1.bytes }
        let chosenBytes = chosen.reduce(0) { $0 + $1.bytes }
        let share = allBytes > 0 ? Double(chosenBytes) / Double(allBytes) : 0
        return Choice(
            folders: chosen,
            freeBytes: Int64(Double(freeable) * share),
            small: untracked.filter { $0.bytes < smallBytes },
            trackedCount: all.count - untracked.count
        )
    }
}

public struct BucketReport: Codable, Sendable {
    public var kind: BucketKind
    /// What `du` reports: allocated blocks, hard links counted once.
    public var apparentBytes: Int64
    /// Blocks only this folder holds. Deleting the folder frees at least this much.
    public var privateBytes: Int64
    /// Private bytes plus shared data whose every copy is inside this bucket.
    public var freeableAloneBytes: Int64
    public var fileCount: Int
    /// The folders where this kind of data starts, such as each __pycache__. Deleting all of them
    /// frees `freeableAloneBytes`. Nil when a trim leaves this kind, and in reports from older versions.
    public var folders: [BuildFolder]? = nil
    /// What deleting `folders` frees. Less than `freeableAloneBytes` when small or tracked folders stay.
    public var foldersFreeBytes: Int64? = nil
    public var smallFolderCount: Int? = nil
    public var smallFolderBytes: Int64? = nil
    public var trackedFolderCount: Int? = nil
}

public struct GroupReport: Codable, Identifiable, Sendable {
    public var id: Int
    public var kind: GroupKind
    public var name: String
    public var paths: [String]
    public var git: GitInfo?
    public var buckets: [BucketReport]
    public var apparentBytes: Int64
    public var privateBytes: Int64
    public var freeableAloneBytes: Int64
    public var selectable: Bool
    public var cleanupCommand: String?
    public var note: String?
    /// Set for checkouts and worktrees a coding agent worked in. Nil when none did, or in older reports.
    public var agent: AgentState? = nil

    public var path: String { paths.first ?? "" }
}

/// Shared copy-on-write data whose copies live in exactly these groups.
/// It is freed only when all of these groups go.
public struct SharedSet: Codable, Sendable {
    /// Contains `Report.outsideGroupID` when a copy lives outside the scanned folders.
    public var groupIDs: [Int]
    public var bytes: Int64
    public var familyCount: Int
}

public struct VolumeInfo: Codable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var availableForImportantUsageBytes: Int64?
}

public struct Report: Codable, Sendable {
    public static let outsideGroupID = -1
    public static let buildOutputID = -2

    public var scannedAt: Date
    public var durationSeconds: Double
    public var roots: [String]
    public var fileCount: Int
    public var errorCount: Int
    public var volume: VolumeInfo
    public var localSnapshots: [String]
    public var groups: [GroupReport]
    public var sharedSets: [SharedSet]
    /// Groups walked in this scan, and groups taken from the cache because FSEvents saw no change.
    public var walkedGroupCount: Int? = nil
    public var reusedGroupCount: Int? = nil
    /// Bytes that clones changed after cloning still share with copies the scan cannot name.
    /// Shown savings can be up to this much too high. See `Aggregator.Result.changedCloneBytes`.
    public var changedCloneBytes: Int64? = nil
    public var changedCloneFiles: Int? = nil
}
