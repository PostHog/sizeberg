import SizeBergCore
import SwiftUI

/// A first scan, or a full scan: folders fill in as they are read. A row is exact once it says Final.
/// On a full scan, dashed bars show what the last scan found.
struct ScanningView: View {
    let progress: ScanProgress
    /// The report shown before this scan started, if any.
    let previous: Report?

    var body: some View {
        let lastScan = lastScanBytes
        let lastTotal = progress.groups.reduce(Int64(0)) { $0 + (lastScan[$1.path] ?? 0) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ScanStatusLine(progress: progress)
                if let fraction = progress.fractionRead, progress.phase == .reading {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("at least \(bytes(progress.knownFreeableBytes))")
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text("can be freed")
                        .foregroundStyle(.secondary)
                    if lastTotal > 0 {
                        Text("· last scan: \(bytes(lastTotal))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text("\(progress.finalGroupCount) of \(progress.groups.count) items final. A final row is exact: every copy of its files has been seen. Other rows show what is certain so far. Dependency folders are read last because deleting them frees little.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            LiveGroupTable(groups: progress.groups, lastScan: lastScan)
        }
    }

    /// Frees-alone bytes per group path in the previous report.
    private var lastScanBytes: [String: Int64] {
        guard let previous else { return [:] }
        var result: [String: Int64] = [:]
        for group in previous.groups where group.kind != .system {
            result[group.path] = group.freeableAloneBytes
        }
        return result
    }
}

/// "Reading files · 4,350,000 files · 1,234 of 3,983 folders · about 1 min left"
struct ScanStatusLine: View {
    let progress: ScanProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Text(progress.phase.rawValue)
                    .font(.headline)
                Text(details(now: context.date))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func details(now: Date) -> String {
        var parts: [String] = []
        if progress.filesRead > 0 {
            parts.append("\(progress.filesRead.formatted()) files")
        }
        if progress.foldersTotal > 0 {
            parts.append("\(progress.foldersDone.formatted()) of \(progress.foldersTotal.formatted()) folders")
        }
        if let seconds = progress.secondsLeft(now: now) {
            parts.append("about \(Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) left")
        } else {
            let elapsed = now.timeIntervalSince(progress.startedAt)
            parts.append("\(Duration.seconds(elapsed.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) so far")
        }
        return parts.joined(separator: " · ")
    }
}

struct LiveGroupTable: View {
    struct Row: Identifiable {
        var group: ScanProgress.Group
        var lastScan: Int64?

        var id: Int { group.id }

        /// Sorts by the last scan when there is one, so rows stay in place while a full scan runs.
        var sortBytes: Int64 { max(lastScan ?? 0, group.knownFreeableBytes) }
    }

    let groups: [ScanProgress.Group]
    let lastScan: [String: Int64]

    var body: some View {
        let rows = groups
            .map { Row(group: $0, lastScan: lastScan[$0.path]) }
            .sorted { left, right in
                if left.sortBytes != right.sortBytes {
                    return left.sortBytes > right.sortBytes
                }
                return left.group.name < right.group.name
            }
        // One scale for every row, so bar lengths compare across rows.
        let scale = max(rows.first?.sortBytes ?? 1, 1)
        Table(rows) {
            TableColumn("Name") { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.group.name)
                    Text(displayPath(row.group.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("Status") { row in
                Text(status(row.group))
                    .foregroundStyle(row.group.isFinal ? .primary : .secondary)
            }
            .width(min: 120, ideal: 190)
            TableColumn("Frees alone") { row in
                HStack(spacing: 10) {
                    FreesBar(known: row.group.knownFreeableBytes, lastScan: row.group.isFinal ? nil : row.lastScan, scale: scale)
                    Spacer(minLength: 0)
                    freesText(row)
                }
            }
            .width(min: 200, ideal: 260)
            TableColumn("du so far") { row in
                Text(row.group.isStarted ? bytes(row.group.apparentBytes) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Files") { row in
                Text(row.group.isStarted ? row.group.fileCount.formatted() : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        }
    }

    private func freesText(_ row: Row) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if row.group.isFinal {
                Text(bytes(row.group.knownFreeableBytes))
                    .fontWeight(.semibold)
            } else if row.group.isStarted {
                Text("at least \(bytes(row.group.knownFreeableBytes))")
            }
            if !row.group.isFinal, let lastScan = row.lastScan {
                Text("last scan \(bytes(lastScan))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    private func status(_ group: ScanProgress.Group) -> String {
        if group.isFinal {
            return "Final"
        }
        if group.isDone {
            return "Checking shared files"
        }
        if !group.isStarted {
            return "Waiting"
        }
        return "Reading, \(group.foldersLeft) of \(group.foldersTotal) folders left"
    }
}

/// Filled part: known now. Dashed outline: what the last scan found.
struct FreesBar: View {
    static let width: CGFloat = 90

    let known: Int64
    let lastScan: Int64?
    let scale: Int64

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.secondary.opacity(0.12))
            if let lastScan, lastScan > 0 {
                Capsule()
                    .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: length(lastScan))
            }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: length(known))
        }
        .frame(width: Self.width, height: 8)
        .accessibilityHidden(true)
    }

    private func length(_ value: Int64) -> CGFloat {
        guard value > 0 else { return 0 }
        // At least a dot, so a small but nonzero value still shows.
        return max(4, Self.width * CGFloat(min(Double(value) / Double(scale), 1)))
    }
}
