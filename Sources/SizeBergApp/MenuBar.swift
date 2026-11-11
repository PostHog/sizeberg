import AppKit
import SizeBergCore
import SwiftUI
import UserNotifications

/// Keeps an eye on the disk while SizeBerg runs. Reading free space costs nothing, so it happens often;
/// scans are rare and run as a separate low-priority process. They also run with the window open, since
/// a window left behind other apps for days would otherwise stop them.
@MainActor
@Observable
final class DiskWatcher {
    static let checkInterval: TimeInterval = 5 * 60

    private(set) var volume = VolumeInfo.current()

    private let model: ScanModel
    private var watch = DiskWatch()
    private var timer: Timer?
    /// A scan that fails leaves the report old, and must not be retried on every check.
    private var lastScanAttempt = Date.distantPast

    init(model: ScanModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Lets macOS line this wake-up up with others.
        timer?.tolerance = 60
        // Late enough for the window to be up at a normal launch, so its own scan with progress runs instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check() }
    }

    var isLow: Bool {
        volume.availableShare < DiskWatch.lowShare
    }

    var iconState: IcebergIcon.State {
        if isLow { return .almostFull }
        return volume.availableShare < DiskWatch.tightShare ? .tight : .roomy
    }

    /// A minimized window or a hidden app still counts: `isVisible` is false for both.
    static var windowIsOpen: Bool {
        NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized || NSApp.isHidden) }
    }

    func scanNow() {
        if Self.windowIsOpen {
            model.scan()
        } else {
            scanInBackground()
        }
    }

    private func check() {
        volume = VolumeInfo.current()
        let events = watch.record(freeBytes: volume.availableBytes, totalBytes: volume.totalBytes)
        events.forEach(warn)
        // A scan would replace the report under an open cleanup sheet.
        guard model.cleanup == nil, Date().timeIntervalSince(lastScanAttempt) > Self.checkInterval else { return }
        let retryIsDue = Date().timeIntervalSince(lastScanAttempt) > DiskWatch.scanInterval
        if !events.isEmpty || (model.reportAge > DiskWatch.scanInterval && retryIsDue) {
            scanInBackground()
        }
    }

    private func scanInBackground() {
        guard !model.isBusy else { return }
        lastScanAttempt = Date()
        let earlierTotal = model.report?.agentWasteTotalBytes
        model.scanInBackground { [weak self] report in
            guard let self, let earlierTotal else { return }
            let growth = report.agentWasteTotalBytes - earlierTotal
            guard growth >= DiskWatch.wasteGrowthBytes else { return }
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

extension Notification.Name {
    /// Asks for the main window, from places without a SwiftUI environment such as a clicked notification.
    static let showMainWindow = Notification.Name("SizeBergShowMainWindow")
}

/// The icon in the menu bar. It is always drawn, so it is also what opens the window on request.
struct MenuBarLabel: View {
    let watcher: DiskWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: IcebergIcon.image(watcher.iconState))
            .accessibilityLabel(watcher.isLow ? "SizeBerg: disk almost full" : "SizeBerg")
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
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
                Button("Open SizeBerg") { NotificationCenter.default.post(name: .showMainWindow, object: nil) }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("\(bytes(watcher.volume.availableBytes)) free of \(bytes(watcher.volume.totalBytes))")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(watcher.isLow ? GroupReport.localWorkColor : Color.primary)
            ProgressView(value: 1 - watcher.volume.availableShare)
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
