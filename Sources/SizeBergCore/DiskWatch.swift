import Foundation

/// What the menu bar warns about, with fixed thresholds: there are no settings to tune.
///
/// - Low space: free space under `lowShare` of the disk. It warns once, and again only after free
///   space went back above `recoveredShare`, so a disk that hovers at the line does not warn every check.
/// - Fast drop: free space fell by `fastDropBytes` within `fastDropWindow`. That is how a leaking tool
///   fills a disk, and it shows hours before the disk is full.
/// - Agent waste growth: temp folders and agent scratch grew by `wasteGrowthBytes` between two scans.
public struct DiskWatch: Sendable {
    public static let lowShare = 0.10
    public static let recoveredShare = 0.12
    public static let fastDropBytes: Int64 = 20_000_000_000
    public static let fastDropWindow: TimeInterval = 60 * 60
    public static let wasteGrowthBytes: Int64 = 20_000_000_000
    /// A background scan this often keeps the numbers in the menu current.
    public static let scanInterval: TimeInterval = 6 * 60 * 60

    public enum Event: Equatable, Sendable {
        case lowSpace(freeBytes: Int64, totalBytes: Int64)
        case fastDrop(bytes: Int64, minutes: Int)
    }

    private struct Sample: Sendable {
        var date: Date
        var freeBytes: Int64
    }

    private var samples: [Sample] = []
    private var warnedLow = false

    public init() {}

    /// Takes one reading of the volume and returns what to warn about now.
    public mutating func record(freeBytes: Int64, totalBytes: Int64, at date: Date = Date()) -> [Event] {
        guard totalBytes > 0 else { return [] }
        var events: [Event] = []
        let share = Double(freeBytes) / Double(totalBytes)
        if share < Self.lowShare, !warnedLow {
            warnedLow = true
            events.append(.lowSpace(freeBytes: freeBytes, totalBytes: totalBytes))
        } else if share >= Self.recoveredShare {
            warnedLow = false
        }

        samples.removeAll { date.timeIntervalSince($0.date) > Self.fastDropWindow }
        if let highest = samples.max(by: { $0.freeBytes < $1.freeBytes }), highest.freeBytes - freeBytes >= Self.fastDropBytes {
            let minutes = max(1, Int(date.timeIntervalSince(highest.date) / 60))
            events.append(.fastDrop(bytes: highest.freeBytes - freeBytes, minutes: minutes))
            // The drop is reported; the next one counts from here.
            samples.removeAll()
        }
        samples.append(Sample(date: date, freeBytes: freeBytes))
        return events
    }
}

/// What a report says can go, for the menu: the same groups the main window offers first.
public struct ReclaimableSummary: Equatable, Sendable {
    public var staleBytes: Int64
    public var agentWasteBytes: Int64
    public var buildOutputBytes: Int64
    /// Everything in agent waste sections, deletable or not, to notice fast growth between scans.
    public var agentWasteTotalBytes: Int64

    public var totalBytes: Int64 { staleBytes + agentWasteBytes + buildOutputBytes }
}

extension Report {
    public var reclaimable: ReclaimableSummary {
        let agentWaste = groups.filter { $0.section != nil }
        return ReclaimableSummary(
            staleBytes: freeableBytes(selection: staleSelection),
            agentWasteBytes: freeableBytes(selection: Set(agentWaste.filter(\.selectable).map(\.id))),
            buildOutputBytes: trimAllBytes,
            agentWasteTotalBytes: agentWaste.reduce(0) { $0 + $1.apparentBytes }
        )
    }

    /// Agent waste that grew by `DiskWatch.wasteGrowthBytes` or more since `earlier`, or nil.
    public func agentWasteGrowth(since earlier: Report) -> Int64? {
        let growth = reclaimable.agentWasteTotalBytes - earlier.reclaimable.agentWasteTotalBytes
        return growth >= DiskWatch.wasteGrowthBytes ? growth : nil
    }

    /// The volume that holds the home folder, read now.
    public static func currentVolume() -> VolumeInfo {
        Scanner.volume(NSHomeDirectory())
    }
}
