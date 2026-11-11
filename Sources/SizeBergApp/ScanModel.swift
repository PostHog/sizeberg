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
        case agentWaste = "Agent waste"
        case stale = "Stale"
        case plan = "Cleanup plan"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: return "square.stack.3d.up"
            case .worktrees: return "arrow.triangle.branch"
            case .folders: return "folder"
            case .caches: return "archivebox"
            case .agentWaste: return "terminal"
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
    private(set) var isBackgroundScanning = false
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
    /// Lists worktrees under their main checkout, and agent waste under its section, instead of as rows of their own.
    var groupItems = true
    /// Main checkouts and agent waste sections whose items are folded away. They start open, so stale worktrees stay in sight.
    var collapsedRepositories: Set<Int> = []
    /// The cleanup sheet's state while it is open.
    var cleanup: CleanupSession?
    /// Items a cleanup deleted. They leave the list at once; the rescan after a big delete can take a
    /// minute, because every shared file the deleted items held has to be counted again.
    private(set) var deletedIDs: Set<Int> = []

    init() {
        // Debug aid for SIZEBERG_SNAPSHOT: "first" scans without a report, "full" runs a full scan over the last one.
        let snapshotScan = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_SCAN"]
        if snapshotScan == "first" {
            DispatchQueue.main.async { self.scan(full: true) }
            return
        }
        report = Report.loadCached()
        if snapshotScan == "full" {
            DispatchQueue.main.async { self.scan(full: true) }
            return
        }
        // Snapshots show the last report as it is, unless "rescan" asks for one.
        if ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT"] != nil, snapshotScan != "rescan" {
            return
        }
        // The last report opens at once, but folders change while the window is closed: rescan when the
        // window comes up and the numbers are a few minutes old. SizeBerg can run for days from the menu
        // bar without a window, and a scan in this process would keep its memory, so nothing scans here until then.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanIfOld() }
        }
    }

    static let freshFor: TimeInterval = 5 * 60

    /// How old the numbers are. Infinite before the first scan, so that one always counts as due.
    var reportAge: TimeInterval {
        report.map { Date().timeIntervalSince($0.scannedAt) } ?? .infinity
    }

    private func rescanIfOld() {
        guard cleanup == nil, reportAge > Self.freshFor else { return }
        scan()
    }

    /// A scan or a cleanup is running: scanning while folders are deleted would report a half state.
    var isBusy: Bool {
        isAnyScanRunning || cleanup?.phase == .running
    }

    var isAnyScanRunning: Bool {
        isScanning || isBackgroundScanning
    }

    /// Scans in a separate low-priority process, which gives its memory back when it exits. Both write
    /// the same cache, so this never runs next to a scan in the window.
    func scanInBackground(then finished: @escaping @MainActor (Report) -> Void) {
        guard !isBusy else { return }
        isBackgroundScanning = true
        Task {
            let scanned = await Task.detached(priority: .background) {
                await Self.runScanHelper()
                return Report.loadCached()
            }.value
            isBackgroundScanning = false
            guard let report = scanned else { return }
            finish(with: report)
            finished(report)
        }
    }

    private nonisolated static let helperTimeout: TimeInterval = 60 * 60

    private nonisolated static func runScanHelper() async {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sizeberg")
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in finished.resume() }
            // Outside an app bundle there is no helper, and the handler never fires.
            guard (try? process.run()) != nil else {
                finished.resume()
                return
            }
            // A stuck helper would otherwise keep every scan and cleanup blocked until the app quits.
            DispatchQueue.global().asyncAfter(deadline: .now() + helperTimeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    func scan(full: Bool = false) {
        guard !isBusy else { return }
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
                let report = Scanner(fullScan: full) { progressInput.yield($0) }.run()
                progressInput.finish()
                try? report.saveToCache()
                return report
            }.value
            finish(with: report)
        }
    }

    /// Forgets every earlier scan, so the next one shows the first-scan screen and timing.
    func clearCache() {
        guard !isBusy else { return }
        try? Report.clearCaches()
        report = nil
        clearSelection()
        focusedID = nil
    }

    /// Group ids are positions in the report and can shift between scans, so the selection, the focused
    /// item and the folded repositories move over by path. Items that are gone drop out.
    private func finish(with report: Report) {
        let previous = self.report
        let carry = { (ids: Set<Int>) -> Set<Int> in
            Self.sameItems(ids, from: previous, in: report)
        }
        selection = carry(selection)
        collapsedRepositories = carry(collapsedRepositories)
        focusedID = focusedID.flatMap { carry([$0]).first }
        self.report = report
        deletedIDs = []
        isScanning = false
        isFullScan = false
        progress = nil
    }

    private static func sameItems(_ ids: Set<Int>, from old: Report?, in new: Report) -> Set<Int> {
        guard let old else { return [] }
        let idByPath = Dictionary(new.groups.map { ($0.kind.rawValue + $0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        return Set(ids.compactMap { id in
            if id == Report.buildOutputID {
                return new.buildOutputItem == nil ? nil : id
            }
            return old.group(id).flatMap { idByPath[$0.kind.rawValue + $0.path] }
        })
    }

    /// Groups the sidebar filter and the size toggle let through, before the search text.
    func groups(in report: Report, filter: Filter) -> [GroupReport] {
        report.items.filter { group in
            guard !deletedIDs.contains(group.id) else { return false }
            switch filter {
            case .all: break
            case .worktrees: guard group.kind == .worktree || group.kind == .mainCheckout else { return false }
            case .folders: guard group.kind == .project else { return false }
            case .caches: guard [.cache, .system, .buildOutput].contains(group.kind), group.section == nil else { return false }
            case .agentWaste: guard group.section != nil else { return false }
            case .stale: guard group.git.map({ $0.status != .active }) ?? false else { return false }
            case .plan: return selection.contains(group.id)
            }
            if hideSmall, group.apparentBytes < Self.smallBytes, !selection.contains(group.id), group.git?.status != .missing {
                return false
            }
            return true
        }
    }

    func matchesSearch(_ group: GroupReport) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return group.name.lowercased().contains(query)
            || group.path.lowercased().contains(query)
            || (group.git?.branch?.lowercased().contains(query) ?? false)
    }

    func visibleGroups(in report: Report) -> [GroupReport] {
        groups(in: report, filter: filter).filter(matchesSearch)
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

    /// Selects the stale worktrees of one repository. Its active worktrees and the checkout stay.
    func selectStale(of main: GroupReport) {
        guard let report else { return }
        selection.formUnion(report.worktrees(of: main).filter(\.goesWithStale).map(\.id))
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
        collapsedRepositories = Set(report.groups.filter { $0.kind == .mainCheckout }.map(\.id) + AgentWasteSection.allCases.map(\.itemID))
    }

    /// Selects the items of one agent waste section that can go. Items in use and size-only items stay.
    func selectDeletable(in section: AgentWasteSection) {
        guard let report else { return }
        selection.formUnion(report.items(in: section).filter(\.selectable).map(\.id))
    }

    /// Opens the confirmation sheet for the selection.
    func prepareCleanup() {
        // A scan may run: the sheet opens on the current report, and only deleting waits for the scan.
        guard let report, !selection.isEmpty, cleanup == nil else { return }
        let plan = CleanupRunner.plan(for: report, selection: selection)
        cleanup = CleanupSession(
            items: plan.steps.map { CleanupSession.Item(step: $0) },
            manual: plan.manual.map { CleanupSession.Manual(id: $0.id, name: $0.name, reason: CleanupRunner.reasonNotIncluded($0)) },
            expectedBytes: Self.expectedBytes(of: plan.steps, in: report),
            deleteBytes: Self.expectedBytes(of: plan.steps.filter { !$0.isTrim }, in: report),
            trimBytes: Self.expectedBytes(of: plan.steps.filter(\.isTrim), in: report),
            keptWithLocalWork: report.groups.filter { $0.git?.status == .staleWithLocalWork && !selection.contains($0.id) }.count
        )
        lookUpIgnoredFiles(for: plan.steps, in: report)
    }

    /// Files git ignores go with a deleted worktree without a word, so the sheet names the ones that
    /// would be lost. Looked up after the sheet opens: git takes a moment per worktree.
    private func lookUpIgnoredFiles(for steps: [CleanupStep], in report: Report) {
        for step in steps where step.kind == .worktree && !step.isTrim && step.groupIDs.count == 1 {
            let mainCheckout = report.group(step.groupIDs[0])?.git?.repoPath
            Task {
                let lost = await Task.detached(priority: .userInitiated) {
                    IgnoredFiles.lost(in: step.path, mainCheckout: mainCheckout)
                }.value
                guard let index = cleanup?.items.firstIndex(where: { $0.id == step.id }) else { return }
                cleanup?.items[index].ignoredFiles = lost ?? []
            }
        }
    }

    func selectBuildOutput() {
        selection.insert(Report.buildOutputID)
    }

    /// Runs the steps one after another, off the main thread, and measures free space around them.
    func runCleanup() {
        // Deleting while a scan reads the same folders would leave the report half old, half new.
        guard var session = cleanup, session.phase == .confirm, !isAnyScanRunning else { return }
        session.phase = .running
        session.freeBefore = CleanupRunner.freeBytes()
        cleanup = session
        Task {
            for index in session.items.indices {
                cleanup?.items[index].status = .running
                let step = session.items[index].step
                let outcome = await Task.detached(priority: .userInitiated) { CleanupRunner.run(step) }.value
                cleanup?.items[index].status = .finished(outcome)
                if outcome.ran {
                    selection.subtract(step.isTrim ? [Report.buildOutputID] : step.groupIDs)
                    if !step.isTrim {
                        deletedIDs.formUnion(step.groupIDs)
                    }
                }
            }
            let ran = (cleanup?.items ?? []).filter(\.ran).map(\.step)
            cleanup?.doneExpectedBytes = report.map { Self.expectedBytes(of: ran, in: $0) } ?? 0
            cleanup?.freeAfter = CleanupRunner.freeBytes()
            cleanup?.phase = .finished
        }
    }

    /// Deleted items free more together than alone; trims add what each frees alone.
    static func expectedBytes(of steps: [CleanupStep], in report: Report) -> Int64 {
        let items = Set(steps.filter { !$0.isTrim }.flatMap(\.groupIDs))
        let trimmed = steps.filter(\.isTrim).reduce(0) { $0 + $1.expectedBytes }
        return report.freeableBytes(selection: items) + trimmed
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
        /// Files git ignores that deleting this worktree also deletes. Nil until looked up.
        var ignoredFiles: [IgnoredFile]?

        var id: String { step.id }

        var ran: Bool {
            if case .finished(let outcome) = status {
                return outcome.ran
            }
            return false
        }
    }

    struct Manual: Identifiable {
        var id: Int
        var name: String
        var reason: String
    }

    var items: [Item]
    var manual: [Manual]
    var expectedBytes: Int64
    /// What the items deleted whole free, and what the build output of the items that stay frees.
    var deleteBytes: Int64
    var trimBytes: Int64
    /// Stale worktrees with local work that the plan leaves alone, so the sheet can say so.
    var keptWithLocalWork: Int
    /// What the scan expected for the steps that ran to the end.
    var doneExpectedBytes: Int64 = 0
    var phase = Phase.confirm
    var freeBefore: Int64 = 0
    var freeAfter: Int64 = 0

    var freedBytes: Int64 { max(0, freeAfter - freeBefore) }

    var deleteItems: [Item] { items.filter { !$0.step.isTrim } }
    var trimItems: [Item] { items.filter(\.step.isTrim) }
}
