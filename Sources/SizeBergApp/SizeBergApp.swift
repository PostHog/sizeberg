import AppKit
import SwiftUI

@main
struct SizeBergApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup("SizeBerg") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Again") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Full Scan") { model.scan(full: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.isScanning)
                Divider()
                Button("Clear Cache") { model.clearCache() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.isScanning)
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
        if let path = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT"] {
            let delay = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.writeSnapshot(to: path)
            }
        }
    }

    /// Debug aid: renders the window to a PNG without needing screen recording permission.
    private static func writeSnapshot(to path: String) {
        // The frame view above the content view draws the window background and toolbar too.
        guard let content = NSApp.windows.first(where: { $0.isVisible })?.contentView,
              let view = content.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
