import AppKit
import SizeBergCore
import SwiftUI

@MainActor
final class ScanModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case worktrees = "Worktrees"
        case folders = "Folders"
        case caches = "Caches"

        var id: String { rawValue }
    }

    static let smallBytes: Int64 = 50_000_000

    @Published private(set) var report: Report?
    @Published private(set) var isScanning = false
    /// Live totals of the running scan. Nil when no scan runs.
    @Published private(set) var progress: ScanProgress?
    @Published var selection: Set<Int> = []
    @Published var focusedID: Int?
    @Published var filter: Filter = .all
    @Published var searchText = ""
    @Published var hideSmall = true
    @Published var copiedPlan = false

    init() {
        // Debug aid for SIZEBERG_SNAPSHOT: start without a report, so the snapshot shows a first scan.
        guard ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_SCAN"] == nil else {
            DispatchQueue.main.async { self.scan(full: true) }
            return
        }
        report = Report.loadCached()
    }

    func scan(full: Bool = false) {
        guard !isScanning else { return }
        isScanning = true
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
        progress = nil
        selection.removeAll()
        focusedID = nil
    }

    func visibleGroups(in report: Report) -> [GroupReport] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return report.groups.filter { group in
            switch filter {
            case .all: break
            case .worktrees: guard group.kind == .worktree || group.kind == .mainCheckout else { return false }
            case .folders: guard group.kind == .project else { return false }
            case .caches: guard group.kind == .cache || group.kind == .system else { return false }
            }
            if hideSmall, group.apparentBytes < Self.smallBytes, !selection.contains(group.id), group.git?.status != .missing {
                return false
            }
            if !query.isEmpty {
                return group.name.lowercased().contains(query)
                    || group.path.lowercased().contains(query)
                    || (group.git?.branch?.lowercased().contains(query) ?? false)
            }
            return true
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
