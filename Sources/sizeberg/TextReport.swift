import SizeBergCore
import Foundation

struct TextReport {
    static let largestCount = 15

    let report: Report

    func render() -> String {
        var lines: [String] = []
        lines.append("SizeBerg: \(report.fileCount.formatted()) files in \(Int(report.durationSeconds.rounded())) s")
        if let walked = report.walkedGroupCount, let reused = report.reusedGroupCount, reused > 0 {
            lines.append("Walked \(walked) changed folders, reused \(reused) unchanged ones from the last scan.")
        }
        lines.append("Disk: \(bytes(report.volume.freeBytes)) free of \(bytes(report.volume.totalBytes))")
        if report.localSnapshots.isEmpty {
            lines.append("No local Time Machine snapshots.")
        } else {
            lines.append("Warning: \(report.localSnapshots.count) local snapshots hold old blocks. Deleting files frees less until they expire.")
        }
        if let changed = report.changedCloneBytes, changed > 0 {
            let files = report.changedCloneFiles ?? 0
            lines.append("Note: \(files) cloned files were changed after cloning and still share \(bytes(changed)) with copies APFS does not name. Savings below can be up to that much too high.")
        }
        if report.errorCount > 0 {
            lines.append("\(report.errorCount.formatted()) entries could not be read.")
        }
        lines.append("")
        lines.append("du would report        \(pad(bytes(report.duTotalBytes), 10))")
        lines.append("Really on disk         \(pad(bytes(report.trueTotalBytes), 10))")
        lines.append("  shared between groups  \(bytes(report.sharedTogetherBytes)) (frees only when every copy goes)")
        lines.append("  shared with outside    \(bytes(report.sharedOutsideBytes)) (other folders or snapshots hold a copy)")

        appendStalePlan(&lines)
        appendLargest(&lines)
        appendCaches(&lines)
        appendSystem(&lines)
        lines.append("")
        lines.append("Open the app, or run with --json, for every group and bucket.")
        return lines.joined(separator: "\n")
    }

    private func appendStalePlan(_ lines: inout [String]) {
        let stale = report.groups.filter(\.isStale)
        let withWork = report.groups.filter { $0.git?.status == .staleWithLocalWork }
        lines.append("")
        lines.append("Stale worktrees: \(stale.count) safe to remove, \(withWork.count) with local work")
        guard !stale.isEmpty || !withWork.isEmpty else { return }
        let selection = report.staleSelection
        lines.append("  Remove the safe ones and clean the package stores: frees \(bytes(report.freeableBytes(selection: selection)))")
        lines.append("  (du would claim \(bytes(report.apparentBytes(selection: selection))) for the same folders)")
        lines.append("")
        lines.append(row("Worktree", "Status", "Last active", "du says", "Frees alone"))
        for group in (stale + withWork).sorted(by: { $0.apparentBytes > $1.apparentBytes }) {
            lines.append(row(
                group.name,
                group.git?.status == .stale ? "stale" : "local work",
                age(group.git?.lastActive),
                bytes(group.apparentBytes),
                bytes(group.freeableAloneBytes)
            ))
        }
    }

    private func appendLargest(_ lines: inout [String]) {
        let largest = report.groups
            .filter { $0.kind == .worktree || $0.kind == .project || $0.kind == .mainCheckout }
            .sorted { $0.freeableAloneBytes > $1.freeableAloneBytes }
            .prefix(Self.largestCount)
        lines.append("")
        lines.append("Largest folders by what deleting them alone frees")
        lines.append(row("Folder", "Biggest bucket", "", "du says", "Frees alone"))
        for group in largest {
            let biggest = group.buckets.max { $0.freeableAloneBytes < $1.freeableAloneBytes }
            lines.append(row(
                group.name,
                biggest.map { $0.kind.title } ?? "",
                biggest.map { bytes($0.freeableAloneBytes) } ?? "",
                bytes(group.apparentBytes),
                bytes(group.freeableAloneBytes)
            ))
        }
    }

    private func appendCaches(_ lines: inout [String]) {
        let caches = report.groups.filter { $0.kind == .cache }.sorted { $0.apparentBytes > $1.apparentBytes }
        guard !caches.isEmpty else { return }
        lines.append("")
        lines.append("Caches (a clean frees the alone column; clones elsewhere keep the rest)")
        lines.append(row("Cache", "Clean with", "", "du says", "Frees alone"))
        for group in caches {
            lines.append(row(group.name, group.cleanupCommand ?? "", "", bytes(group.apparentBytes), bytes(group.freeableAloneBytes)))
        }
    }

    private func appendSystem(_ lines: inout [String]) {
        let system = report.groups.filter { $0.kind == .system }
        guard !system.isEmpty else { return }
        lines.append("")
        lines.append("Containers and system")
        for group in system {
            lines.append("  \(pad(group.name, 22)) \(pad(bytes(group.apparentBytes), 10)) on disk")
            for noteLine in (group.note ?? "").split(separator: "\n") {
                lines.append("      \(noteLine)")
            }
        }
    }

    private func row(_ name: String, _ second: String, _ third: String, _ fourth: String, _ fifth: String) -> String {
        "  " + pad(String(name.prefix(34)), 35) + pad(String(second.prefix(28)), 29) + pad(third, 12) + lpad(fourth, 10) + lpad(fifth, 13)
    }

    private func bytes(_ value: Int64) -> String {
        ByteFormat.string(value)
    }

    private func age(_ date: Date?) -> String {
        guard let date else { return "?" }
        let days = Int(-date.timeIntervalSinceNow / 86_400)
        return days == 0 ? "today" : "\(days) d ago"
    }

    private func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private func lpad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
    }
}
