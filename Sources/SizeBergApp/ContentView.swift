import SizeBergCore
import SwiftUI

/// Sidebar with filters and disk totals, the item list or map in the middle, details in the inspector.
struct ContentView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(report: model.report)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .navigationTitle(model.filter.rawValue)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Name, path or branch")
        }
        .onAppear(perform: prepareSnapshot)
        .sheet(isPresented: Binding(get: { model.cleanup != nil }, set: { if !$0 { model.closeCleanup() } })) {
            CleanupSheet()
        }
    }

    @ViewBuilder
    private var detail: some View {
        @Bindable var model = model
        if let progress = model.progress, progress.phase != .discovering, model.report == nil || model.isFullScan {
            ScanningView(progress: progress, previous: model.report)
        } else if let report = model.report {
            MainContent(report: report)
                .inspector(isPresented: $model.showInspector) {
                    InspectorView(report: report)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
                }
        } else {
            EmptyStateView()
        }
    }

    private var subtitle: String {
        if model.isScanning {
            return model.progress?.phase.rawValue ?? "Starting"
        }
        guard let report = model.report else { return "" }
        let scanned = "scanned \(report.scannedAt.formatted(.relative(presentation: .named)))"
        let count = model.visibleGroups(in: report).count
        return "\(count) \(count == 1 ? "item" : "items") · \(scanned)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        if model.report != nil {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: $model.viewMode) {
                    ForEach(ScanModel.ViewMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Show items as a list or as a map of what each one frees")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isScanning {
                ToolbarScanStatus(progress: model.progress)
            }
            Button {
                model.scan()
            } label: {
                Label(model.report == nil ? "Scan" : "Scan again", systemImage: "arrow.clockwise")
            }
            .help("Scan again. Only folders that changed are read.")
            .disabled(model.isBusy)
            Menu {
                Toggle("Hide items under 50 MB", isOn: $model.hideSmall)
                Toggle("Group worktrees under main checkout", isOn: $model.groupWorktrees)
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
            }
            .help("Filter the list")
        }
        if model.report != nil {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label(model.showInspector ? "Hide inspector" : "Show inspector", systemImage: "sidebar.trailing")
                }
                .help(model.showInspector ? "Hide inspector" : "Show inspector")
            }
        }
    }
}

extension ContentView {
    /// Debug aid for SIZEBERG_SNAPSHOT: show a populated plan and inspector.
    private func prepareSnapshot() {
        guard ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT"] != nil, let report = model.report else { return }
        model.selectStale()
        model.focusedID = report.groups
            .filter(\.isStale)
            .max { $0.freeableAloneBytes < $1.freeableAloneBytes }?
            .id
        if ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_VIEW"] == "map" {
            model.viewMode = .map
        }
        if let name = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_REPO"],
           let main = report.groups.first(where: { $0.kind == .mainCheckout && $0.name == name }) {
            model.focusedID = main.id
        }
        if let name = ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_FILTER"], let filter = ScanModel.Filter(rawValue: name) {
            model.filter = filter
        }
        switch ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_PLAN"] {
        case "empty":
            model.clearSelection()
        case "both":
            model.selectBuildOutput()
        case "build":
            model.clearSelection()
            model.selectBuildOutput()
            model.focusedID = Report.buildOutputID
        default:
            break
        }
        // Opens the confirmation only; nothing runs without pressing Delete.
        if ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT_CLEANUP"] != nil {
            model.prepareCleanup()
        }
    }
}

/// The list or the map, with notices above it and the cleanup plan floating below.
struct MainContent: View {
    let report: Report
    @Environment(ScanModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !report.localSnapshots.isEmpty {
                NoticeBar(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "\(report.localSnapshots.count) local Time Machine snapshots hold old blocks. Deleting files frees less until they expire, and files can look shared when they are not."
                )
            }
            if let changed = report.changedCloneBytes, changed > 0 {
                let files = report.changedCloneFiles ?? 0
                NoticeBar(
                    symbol: "info.circle.fill",
                    tint: .secondary,
                    text: "\(files.formatted()) cloned \(files == 1 ? "file was" : "files were") changed after cloning and still \(files == 1 ? "shares" : "share") \(bytes(changed)) with copies APFS does not name. Savings shown here can be up to that much too high."
                )
            }
            switch model.viewMode {
            case .list:
                GroupTable(report: report)
            case .map:
                TreemapView(report: report)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PlanBar(report: report)
        }
    }
}

/// One line of context above the content, such as snapshots that keep deleted blocks.
struct NoticeBar: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.background.secondary)
    }
}

/// Small status next to the toolbar buttons: share read, with a bar when the total is known.
struct ToolbarScanStatus: View {
    let progress: ScanProgress?

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = progress?.fractionRead, progress?.phase == .reading {
                ProgressView(value: fraction)
                    .frame(width: 80)
                Text("\(Int(fraction * 100))%")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

struct EmptyStateView: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("See what deleting really frees", systemImage: "internaldrive")
        } description: {
            Text("On APFS, pnpm and uv install dependencies as copy-on-write clones, so du and Finder count the same bytes many times. This scan follows the clones and shows what each worktree, folder and cache really holds.")
        } actions: {
            if model.isScanning {
                ProgressView("Finding folders")
            } else {
                Button("Scan ~/workspace and dev caches") { model.scan() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }
}
