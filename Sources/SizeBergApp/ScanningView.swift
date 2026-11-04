import SizeBergCore
import SwiftUI

/// First scan, before any report exists: folders fill in as they are read, with numbers that only grow.
struct ScanningView: View {
    let progress: ScanProgress

    var body: some View {
        let confirmed = progress.groups.reduce(Int64(0)) { $0 + $1.confirmedFreeableBytes }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ScanStatusLine(progress: progress)
                if let fraction = progress.fractionRead, progress.phase == .reading {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bytes(confirmed))
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text("can be freed, counted so far")
                        .foregroundStyle(.secondary)
                }
                Text("These files share no blocks with anything. Shared clones are matched at the end, and dependency folders are read last because deleting them frees little.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            LiveGroupTable(groups: progress.groups)
        }
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
    let groups: [ScanProgress.Group]

    var body: some View {
        let rows = groups.sorted { left, right in
            if left.confirmedFreeableBytes != right.confirmedFreeableBytes {
                return left.confirmedFreeableBytes > right.confirmedFreeableBytes
            }
            return left.name < right.name
        }
        Table(rows) {
            TableColumn("Name") { group in
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                    Text(displayPath(group.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            TableColumn("Status") { group in
                Text(status(group))
                    .foregroundStyle(group.isDone ? .primary : .secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Frees at least") { group in
                Text(group.isStarted ? bytes(group.confirmedFreeableBytes) : "")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 110)
            TableColumn("du so far") { group in
                Text(group.isStarted ? bytes(group.apparentBytes) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Files") { group in
                Text(group.isStarted ? group.fileCount.formatted() : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        }
    }

    private func status(_ group: ScanProgress.Group) -> String {
        if group.isDone {
            return "Read"
        }
        if !group.isStarted {
            return "Waiting"
        }
        return "Reading, \(group.foldersLeft) of \(group.foldersTotal) folders left"
    }
}
