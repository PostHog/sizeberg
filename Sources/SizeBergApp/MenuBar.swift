import AppKit
import SizeBergCore
import SwiftUI
import UserNotifications

/// Keeps an eye on the disk while SizeBerg runs. Reading free space costs nothing, so it happens often;
/// scans are rare, run as a separate low-priority process, and never while the window is open, where
/// the window's own scans keep the numbers current.
@MainActor
@Observable
final class DiskWatcher {
    static let checkInterval: TimeInterval = 5 * 60

    private(set) var volume = Report.currentVolume()
    /// Opens the main window. The menu bar label sets it: only a SwiftUI view can reach openWindow.
    var openMainWindow: (() -> Void)?

    private let model: ScanModel
    private var watch = DiskWatch()
    private var timer: Timer?

    init(model: ScanModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Late enough for the window to be up at a normal launch, so its own scan with progress runs instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check() }
    }

    var freeBytes: Int64 {
        volume.availableForImportantUsageBytes ?? volume.freeBytes
    }

    var isLow: Bool {
        volume.totalBytes > 0 && Double(freeBytes) / Double(volume.totalBytes) < DiskWatch.lowShare
    }

    var usedShare: Double {
        volume.totalBytes > 0 ? 1 - Double(freeBytes) / Double(volume.totalBytes) : 0
    }

    static var windowIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func scanNow() {
        if Self.windowIsOpen {
            model.scan()
        } else {
            scanInBackground()
        }
    }

    private func check() {
        volume = Report.currentVolume()
        let events = watch.record(freeBytes: freeBytes, totalBytes: volume.totalBytes)
        events.forEach(warn)
        let isOld = model.report.map { Date().timeIntervalSince($0.scannedAt) > DiskWatch.scanInterval } ?? true
        if !events.isEmpty || isOld, !Self.windowIsOpen {
            scanInBackground()
        }
    }

    private func scanInBackground() {
        let earlier = model.report
        model.scanInBackground { [weak self] report in
            guard let self, let earlier, let growth = report.agentWasteGrowth(since: earlier) else { return }
            self.notify(
                title: "Temp folders are growing fast",
                body: "Agent and temp folders grew \(bytes(growth)) since the last scan. \(self.canFreeText)"
            )
        }
    }

    private func warn(_ event: DiskWatch.Event) {
        switch event {
        case let .lowSpace(free, total):
            notify(title: "Disk almost full", body: "\(bytes(free)) free of \(bytes(total)). \(canFreeText)")
        case let .fastDrop(dropped, minutes):
            notify(title: "Free space is dropping fast", body: "\(bytes(dropped)) gone in the last \(minutes) minutes. \(canFreeText)")
        }
    }

    private var canFreeText: String {
        guard let total = model.report?.reclaimable.totalBytes, total > 0 else { return "Open SizeBerg to see where it went." }
        return "SizeBerg can free about \(bytes(total))."
    }

    private func notify(title: String, body: String) {
        // A binary run outside an app bundle has no notification center and would crash here.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// The icon in the menu bar. It is always drawn, so it also hands openWindow to the watcher.
struct MenuBarLabel: View {
    let watcher: DiskWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: IcebergIcon.image(usedShare: watcher.usedShare, isLow: watcher.isLow))
            .accessibilityLabel(watcher.isLow ? "SizeBerg: disk almost full" : "SizeBerg")
            .onAppear {
                watcher.openMainWindow = { openWindow(id: "main") }
            }
    }
}

/// What opens from the menu bar: free space, what can go, and the few actions there are.
struct MenuBarContent: View {
    let watcher: DiskWatcher
    let model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            freeSpace
            if let report = model.report {
                Divider()
                reclaimable(report.reclaimable)
                Divider()
                Text(model.isBusy ? "Scanning…" : "Scanned \(report.scannedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open SizeBerg") { watcher.showWindow() }
                    .keyboardShortcut(.defaultAction)
                Button("Scan Now") { watcher.scanNow() }
                    .disabled(model.isBusy)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var freeSpace: some View {
        let total = max(watcher.volume.totalBytes, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(bytes(watcher.freeBytes)) free of \(bytes(watcher.volume.totalBytes))")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(watcher.isLow ? AnyShapeStyle(GroupReport.localWorkColor) : AnyShapeStyle(.primary))
            ProgressView(value: Double(total - watcher.freeBytes), total: Double(total))
                .tint(watcher.isLow ? GroupReport.localWorkColor : .accentColor)
        }
    }

    private func reclaimable(_ summary: ReclaimableSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Can free about \(bytes(summary.totalBytes))")
                .font(.headline)
                .monospacedDigit()
            line("Stale worktrees and stores", summary.staleBytes)
            line("Agent waste", summary.agentWasteBytes)
            line("Build output and caches", summary.buildOutputBytes)
        }
    }

    private func line(_ title: String, _ value: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(bytes(value))
                .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
