import SizeBergCore
import SwiftUI

/// Filters with counts, and what the disk holds at the bottom.
struct SidebarView: View {
    let report: Report?
    @Environment(ScanModel.self) private var model

    var body: some View {
        // List selection on macOS wants an optional; the model always has a filter.
        let selection = Binding<ScanModel.Filter?>(
            get: { model.filter },
            set: { if let filter = $0 { model.filter = filter } }
        )
        List(selection: selection) {
            Section("Items") {
                row(.all)
                row(.worktrees)
                row(.folders)
                row(.caches)
            }
            Section("Cleanup") {
                row(.stale)
                row(.plan)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let report {
                DiskSummary(report: report)
            }
        }
    }

    private func row(_ filter: ScanModel.Filter) -> some View {
        Label(filter.rawValue, systemImage: filter.symbol)
            .badge(report.map { model.groups(in: $0, filter: filter).count } ?? 0)
            .tag(filter)
    }
}

/// Free space, and what du claims against what is really on disk.
struct DiskSummary: View {
    let report: Report

    var body: some View {
        let total = report.volume.totalBytes
        let used = max(0, total - report.volume.freeBytes)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(used), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Disk used")
                Text("\(bytes(report.volume.freeBytes)) free of \(bytes(total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("du says")
                        .foregroundStyle(.secondary)
                    Text(bytes(report.duTotalBytes))
                        .strikethrough(color: .secondary)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                GridRow {
                    Text("Really on disk")
                        .foregroundStyle(.secondary)
                    Text(bytes(report.trueTotalBytes))
                        .fontWeight(.medium)
                }
                GridRow {
                    Text("Shared clones")
                        .foregroundStyle(.secondary)
                    Text(bytes(report.sharedTogetherBytes))
                }
            }
            .font(.caption)
            .monospacedDigit()
            Text(scanFacts)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scanFacts: String {
        var parts = ["\(report.fileCount.formatted()) files in \(Int(report.durationSeconds.rounded())) s"]
        if let reused = report.reusedGroupCount, reused > 0, let walked = report.walkedGroupCount {
            parts.append("\(walked) changed, \(reused) reused")
        }
        if report.errorCount > 0 {
            parts.append("\(report.errorCount.formatted()) unreadable")
        }
        return parts.joined(separator: " · ")
    }
}
