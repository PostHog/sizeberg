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
    /// Lists worktrees under their main checkout instead of as rows of their own.
    var groupWorktrees = true
    /// Main checkouts whose worktrees are folded away. Repositories start open, so stale worktrees stay in sight.
    var collapsedRepositories: Set<Int> = []
    /// The cleanup sheet's state while it is open.
    var cleanup: CleanupSession?

    init() {
        // Debug aid for SIZEBERG_SNAPSHOT: "first" scans without a report, "full" runs a full scan over the last one.
        let snapshotScan = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_SCAN"]
        if snapshotScan == "first" {
            DispatchQueue.main.async { self.scan(full: true) }
            return
        }
        report = Report.loadCached()
        guard snapshotScan == "full" else { return }
        DispatchQueue.main.async { self.scan(full: true) }
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

    func collapseAllRepositories() {
        guard let report else { return }
        collapsedRepositories = Set(report.groups.filter { $0.kind == .mainCheckout }.map(\.id))
    }

    /// Opens the confirmation sheet for the selection.
    func prepareCleanup() {
        guard let report, !selection.isEmpty, !isScanning else { return }
        let plan = CleanupRunner.plan(for: report, selection: selection)
        cleanup = CleanupSession(
            items: plan.steps.map { CleanupSession.Item(step: $0) },
            manual: plan.manual.map { CleanupSession.Manual(name: $0.name, reason: $0.reason) },
            expectedBytes: report.freeableBytes(selection: Set(plan.steps.map(\.id)))
        )
    }

    /// Runs the steps one after another, off the main thread, and measures free space around them.
    func runCleanup() {
        guard var session = cleanup, session.phase == .confirm else { return }
        session.phase = .running
        session.freeBefore = CleanupRunner.freeBytes()
        cleanup = session
        Task {
            for index in session.items.indices {
                cleanup?.items[index].status = .running
                let step = session.items[index].step
                let outcome = await Task.detached(priority: .userInitiated) { CleanupRunner.run(step) }.value
                cleanup?.items[index].status = .finished(outcome)
                if outcome == .done {
                    selection.remove(step.id)
                }
            }
            cleanup?.freeAfter = CleanupRunner.freeBytes()
            cleanup?.phase = .finished
        }
    }

    /// Closes the sheet. After a run, scans again so the list shows what is left.
    func closeCleanup() {
        guard let session = cleanup, session.phase != .running else { return }
        cleanup = nil
        if session.phase == .finished {
            scan()
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

/// What the cleanup sheet shows: the plan, then each step's progress and the space freed.
struct CleanupSession {
    enum Phase {
        case confirm
        case running
        case finished
    }

    enum Status: Equatable {
        case waiting
        case running
        case finished(CleanupOutcome)
    }

    struct Item: Identifiable {
        var step: CleanupStep
        var status: Status = .waiting

        var id: Int { step.id }
    }

    struct Manual: Identifiable {
        var name: String
        var reason: String

        var id: String { name }
    }

    var items: [Item]
    var manual: [Manual]
    var expectedBytes: Int64
    var phase = Phase.confirm
    var freeBefore: Int64 = 0
    var freeAfter: Int64 = 0

    var freedBytes: Int64 { max(0, freeAfter - freeBefore) }
}
