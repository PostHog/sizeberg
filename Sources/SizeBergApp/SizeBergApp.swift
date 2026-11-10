import AppKit
import SwiftUI

@main
struct SizeBergApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ScanModel()

    var body: some Scene {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM binary starts as a background process; this gives it a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        // Debug aid for SIZEBERG_SNAPSHOT: check the dark appearance without changing the system setting.
        if ProcessInfo.processInfo.environment["SIZEBERG_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
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
        true
    }
}
