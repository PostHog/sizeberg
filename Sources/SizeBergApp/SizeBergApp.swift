import AppKit
import ServiceManagement
import SizeBergCore
import SwiftUI
import UserNotifications

@main
struct SizeBergApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: ScanModel
    @State private var watcher: DiskWatcher

    init() {
        let model = ScanModel()
        _model = State(initialValue: model)
        _watcher = State(initialValue: DiskWatcher(model: model))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(watcher: watcher, model: model)
        } label: {
            MenuBarLabel(watcher: watcher)
                .onAppear { appDelegate.watcher = watcher }
        }
        .menuBarExtraStyle(.menu)

        // One window: every view shows the same scan, so a second window would only repeat it.
        Window("SizeBerg", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1480, height: 900)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
            }
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
                Button("Full Scan") { model.scan(full: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
                Divider()
                Button("Clean Up Selection…") { model.prepareCleanup() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(model.cleanup != nil || model.selection.isEmpty)
                Divider()
                Button("Clear Cache") { model.clearCache() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.isBusy)
            }
            CommandGroup(before: .sidebar) {
                Button("As List") { model.viewMode = .list }
                    .keyboardShortcut("1")
                Button("As Map") { model.viewMode = .map }
                    .keyboardShortcut("2")
                Divider()
                Toggle("Hide Items Under 50 MB", isOn: $model.hideSmall)
                Toggle("Group Worktrees and Agent Waste", isOn: $model.groupItems)
                Button("Collapse All Groups") { model.collapseAllRepositories() }
                    .disabled(!model.groupItems)
                Button("Expand All Groups") { model.collapsedRepositories.removeAll() }
                    .disabled(!model.groupItems)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the menu bar label, for opening the window from a notification.
    var watcher: DiskWatcher?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = Self.isLoginLaunch
        // A bare SwiftPM binary starts as a background process; this gives it a Dock icon and focus.
        // Started at login, SizeBerg stays in the menu bar until someone opens the window.
        NSApp.setActivationPolicy(launchedAtLogin ? .accessory : .regular)
        // Debug aid for SIZEBERG_SNAPSHOT: check the dark appearance without changing the system setting.
        if ProcessInfo.processInfo.environment["SIZEBERG_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The system marks the launch event of a login item.
    private static var isLoginLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Adds the login item once. If someone removes it in System Settings, it stays removed.
    private static func registerLoginItemOnce() {
        let key = "registeredLoginItem"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    /// The Dock icon stays only while the window is open; the menu bar item remains.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing.canBecomeMain else { return }
        DispatchQueue.main.async {
            if !DiskWatcher.windowIsOpen {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { watcher?.showWindow() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        Self.registerLoginItemOnce()
        if launchedAtLogin {
            // SwiftUI opens the window on every launch; at login it should not appear.
            DispatchQueue.main.async {
                NSApp.windows.filter(\.canBecomeMain).forEach { $0.close() }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Starts the daily update check of Developer ID builds.
        _ = Updates.shared
        if let path = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT"] {
            let delay = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.writeSnapshot(to: path)
            }
        }
    }

    /// Debug aid: captures the window to a PNG with the system screenshot tool. Liquid Glass and split views
    /// are drawn by the window server, so copying the view hierarchy leaves them blank.
    /// Needs screen recording permission for the app that launched SizeBerg, such as the terminal.
    private static func writeSnapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let screenHeight = NSScreen.screens.first?.frame.height else { return }
        // A window-only capture skips glass layers that the window server composites on its own,
        // so capture the window's area of the screen with the window in front.
        window.orderFrontRegardless()
        let frame = window.frame
        let region = "\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", region, path]
        try? capture.run()
        capture.waitUntilExit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
