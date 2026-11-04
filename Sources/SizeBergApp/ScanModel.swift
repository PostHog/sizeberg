import AppKit
import SizeBergCore
import SwiftUI

@MainActor
@Observable
final class ScanModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All items"
        case worktrees = "Worktrees"
        case folders = "Folders"
        case caches = "Caches"
        case stale = "Stale"
        case plan = "Cleanup plan"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: return "square.stack.3d.up"
            case .worktrees: return "arrow.triangle.branch"
            case .folders: return "folder"
            case .caches: return "archivebox"
            case .stale: return "clock.badge.exclamationmark"
            case .plan: return "checklist"
            }
        }
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        case list = "List"
        case map = "Map"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .list: return "list.bullet"
            case .map: return "rectangle.split.3x3"
            }
        }
    }

    static let smallBytes: Int64 = 50_000_000

    private(set) var report: Report?
    private(set) var isScanning = false
    /// A full scan shows the live table over the old report, with the old numbers for comparison.
    private(set) var isFullScan = false
    /// Live totals of the running scan. Nil when no scan runs.
    private(set) var progress: ScanProgress?
    var selection: Set<Int> = []
    var focusedID: Int?
    var filter: Filter = .all
    var searchText = ""
    var hideSmall = true
    var copiedPlan = false
    var viewMode: ViewMode = .list
    var showInspector = true

    init() {
        // Debug aid for SIZEBERG_SNAPSHOT: "first" starts without a report, "full" runs a full scan over it.
        let snapshotScan = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_SCAN"]
        if snapshotScan != "first" {
            report = Report.loadCached()
        }
        if snapshotScan != nil {
            DispatchQueue.main.async { self.scan(full: true) }
        }
    }

    func scan(full: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
        isFullScan = full
        progress = nil
        let (updates, progressInput) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        Task {
            for await update in updates where isScanning {
                progress = update
            }
        }
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                let report = Scanner(roots: Scanner.defaultRoots, fullScan: full) { progressInput.yield($0) }.run()
                progressInput.finish()
                try? report.saveToCache()
                return report
            }.value
            finish(with: report)
        }
    }

    /// Forgets every earlier scan, so the next one shows the first-scan screen and timing.
    func clearCache() {
        guard !isScanning else { return }
        try? Report.clearCaches()
        report = nil
        selection.removeAll()
        focusedID = nil
    }

    private func finish(with report: Report) {
        self.report = report
        isScanning = false
        isFullScan = false
        progress = nil
        selection.removeAll()
        focusedID = nil
    }

    /// Groups the sidebar filter and the size toggle let through, before the search text.
    func groups(in report: Report, filter: Filter) -> [GroupReport] {
        report.groups.filter { group in
            switch filter {
            case .all: break
            case .worktrees: guard group.kind == .worktree || group.kind == .mainCheckout else { return false }
            case .folders: guard group.kind == .project else { return false }
            case .caches: guard group.kind == .cache || group.kind == .system else { return false }
            case .stale: guard group.git.map({ $0.status != .active }) ?? false else { return false }
            case .plan: return selection.contains(group.id)
            }
            if hideSmall, group.apparentBytes < Self.smallBytes, !selection.contains(group.id), group.git?.status != .missing {
                return false
            }
            return true
        }
    }

    func visibleGroups(in report: Report) -> [GroupReport] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let groups = groups(in: report, filter: filter)
        guard !query.isEmpty else { return groups }
        return groups.filter { group in
            group.name.lowercased().contains(query)
                || group.path.lowercased().contains(query)
                || (group.git?.branch?.lowercased().contains(query) ?? false)
        }
    }

    func isSelected(_ id: Int) -> Bool {
        selection.contains(id)
    }

    func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(id) },
            set: { isOn in
                if isOn {
                    self.selection.insert(id)
                } else {
                    self.selection.remove(id)
                }
            }
        )
    }

    func toggle(_ id: Int) {
        guard let group = report?.group(id), group.selectable else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func selectStale() {
        guard let report else { return }
        selection = report.staleSelection
    }

    func clearSelection() {
        selection.removeAll()
    }

    func copyPlan() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.cleanupPlan(selection: selection), forType: .string)
        copiedPlan = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedPlan = false
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}
