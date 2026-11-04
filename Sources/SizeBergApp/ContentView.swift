import SizeBergCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Group {
            if let report = model.report {
                MainView(report: report)
            } else if let progress = model.progress, progress.phase != .discovering {
                ScanningView(progress: progress)
            } else {
                EmptyStateView()
            }
        }
        .onAppear(perform: prepareSnapshot)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    ToolbarScanStatus(progress: model.progress)
                }
                Button {
                    model.scan()
                } label: {
                    Label(model.report == nil ? "Scan" : "Scan again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }
        }
    }
}

extension ContentView {
    /// Debug aid for SIZEBERG_SNAPSHOT: show a populated plan and detail panel.
    private func prepareSnapshot() {
        guard ProcessInfo.processInfo.environment["SIZEBERG_SNAPSHOT"] != nil, let report = model.report else { return }
        model.selectStale()
        model.focusedID = report.groups
            .filter { $0.git?.status == .stale }
            .max { $0.freeableAloneBytes < $1.freeableAloneBytes }?
            .id
    }
}

/// Small status next to the toolbar buttons: phase and share read, with a bar when the total is known.
struct ToolbarScanStatus: View {
    let progress: ScanProgress?

    var body: some View {
        HStack(spacing: 6) {
            if let fraction = progress?.fractionRead, progress?.phase == .reading {
                ProgressView(value: fraction)
                    .frame(width: 80)
                Text("\(progress?.phase.rawValue ?? "") \(Int(fraction * 100))%")
            } else {
                ProgressView().controlSize(.small)
                Text(progress?.phase.rawValue ?? "Starting")
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("See what deleting things really frees")
                .font(.title2.weight(.semibold))
            Text("On APFS, pnpm and uv install dependencies as copy-on-write clones, so du and Finder count the same bytes many times. This scan follows the clones and shows what each worktree, folder and cache really holds.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if model.isScanning {
                ProgressView("Finding folders")
            } else {
                Button("Scan ~/workspace and dev caches") { model.scan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainView: View {
    let report: Report

    var body: some View {
        VStack(spacing: 0) {
            SummaryStrip(report: report)
            if !report.localSnapshots.isEmpty {
                SnapshotBanner(count: report.localSnapshots.count)
            }
            if let bytes = report.changedCloneBytes, bytes > 0 {
                ChangedCloneBanner(sharedBytes: bytes, files: report.changedCloneFiles ?? 0)
            }
            Divider()
            HSplitView {
                GroupTable(report: report)
                    .frame(minWidth: 640, idealWidth: 700)
                VSplitView {
                    TreemapView(report: report)
                        .frame(minHeight: 300, idealHeight: 420)
                    DetailPanel(report: report)
                        .frame(minHeight: 180, idealHeight: 240)
                }
                .frame(minWidth: 420)
            }
            Divider()
            PlanBar(report: report)
        }
    }
}

struct SummaryStrip: View {
    let report: Report
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        let staleCount = report.groups.filter { $0.git?.status == .stale }.count
        HStack(alignment: .top, spacing: 10) {
            StatCard(
                title: "Free on disk",
                value: bytes(report.volume.freeBytes),
                caption: "of \(bytes(report.volume.totalBytes))"
            )
            StatCard(
                title: "du would report",
                value: bytes(report.duTotalBytes),
                caption: "for the scanned folders",
                isMuted: true
            )
            StatCard(
                title: "Really on disk",
                value: bytes(report.trueTotalBytes),
                caption: "\(bytes(report.sharedTogetherBytes)) of it is shared clones"
            )
            StatCard(
                title: "Stale worktrees",
                value: "\(staleCount)",
                caption: "with store cleanup they free \(bytes(report.freeableBytes(selection: report.staleSelection)))"
            )
            StatCard(
                title: "Selection frees",
                value: model.selection.isEmpty ? "None yet" : bytes(report.freeableBytes(selection: model.selection)),
                caption: model.selection.isEmpty
                    ? "select rows or tiles"
                    : "du would claim \(bytes(report.apparentBytes(selection: model.selection)))",
                isHighlighted: !model.selection.isEmpty
            )
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Scanned \(report.scannedAt.formatted(.relative(presentation: .named)))")
                Text("\(report.fileCount.formatted()) files in \(Int(report.durationSeconds.rounded())) s")
                if let reused = report.reusedGroupCount, reused > 0, let walked = report.walkedGroupCount {
                    Text("\(walked) changed folders walked, \(reused) reused")
                }
                if report.errorCount > 0 {
                    Text("\(report.errorCount.formatted()) unreadable")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let caption: String
    var isMuted = false
    var isHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isMuted ? .secondary : .primary)
                .strikethrough(isMuted, color: .secondary)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 170, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
        )
    }
}

struct SnapshotBanner: View {
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(count) local Time Machine snapshots hold old blocks. Deleting files frees less until they expire, and files can look shared when they are not.")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }
}

/// Copies changed after cloning share blocks with families APFS cannot name, so savings can be too high.
struct ChangedCloneBanner: View {
    let sharedBytes: Int64
    let files: Int

    var body: some View {
        HStack {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text("\(files.formatted()) cloned \(files == 1 ? "file was" : "files were") changed after cloning and still \(files == 1 ? "shares" : "share") \(bytes(sharedBytes)) with copies APFS does not name. Savings shown here can be up to that much too high.")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}

struct GroupTable: View {
    let report: Report
    @EnvironmentObject private var model: ScanModel
    @State private var sortOrder = [KeyPathComparator(\GroupReport.freeableAloneBytes, order: .reverse)]

    var body: some View {
        let rows = model.visibleGroups(in: report).sorted(using: sortOrder)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $model.filter) {
                    ForEach(ScanModel.Filter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Filter by name, path or branch", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120)
                Toggle("Hide under 50 MB", isOn: $model.hideSmall)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .padding(8)
            Table(rows, selection: $model.focusedID, sortOrder: $sortOrder) {
                TableColumn("") { group in
                    Toggle("", isOn: model.binding(for: group.id))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(!group.selectable)
                }
                .width(22)
                TableColumn("Name", value: \.name) { group in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name).lineLimit(1)
                        Text(group.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 140, ideal: 190)
                TableColumn("Status", value: \.statusSortKey) { group in
                    StatusBadge(group: group)
                }
                .width(min: 80, ideal: 100)
                TableColumn("Frees alone", value: \.freeableAloneBytes) { group in
                    Text(group.freesAloneText)
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 90)
                TableColumn("du says", value: \.apparentBytes) { group in
                    Text(bytes(group.apparentBytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 80)
                TableColumn("Last active", value: \.lastActiveSortKey) { group in
                    Text(group.lastActiveText).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 85)
            }
        }
    }
}

struct DetailPanel: View {
    let report: Report
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        ScrollView {
            if let id = model.focusedID, let group = report.group(id) {
                GroupDetail(report: report, group: group)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a row or a tile to see what it holds and how to clean it up.")
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct GroupDetail: View {
    let report: Report
    let group: GroupReport
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(group.name).font(.title3.weight(.semibold))
                StatusBadge(group: group)
                Spacer()
                if group.selectable {
                    Toggle("In cleanup plan", isOn: model.binding(for: group.id))
                        .toggleStyle(.checkbox)
                }
            }
            HStack(spacing: 6) {
                Text(displayPath(group.path))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") { model.reveal(group.path) }
                    .controlSize(.small)
            }
            if let git = group.git {
                gitFacts(git)
            }
            if !group.buckets.isEmpty {
                bucketGrid
            }
            let shared = report.sharedWithOthersBytes(group.id)
            if shared > 0 {
                Text("\(bytes(shared)) more is shared with other folders or caches. It frees only when every copy goes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let note = group.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let command = group.cleanupCommand {
                HStack(spacing: 6) {
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    Button("Copy") { model.copy(command) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func gitFacts(_ git: GitInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            if let branch = git.branch {
                GridRow { label("Branch"); Text(branch).textSelection(.enabled) }
            }
            if let lastActive = git.lastActive {
                GridRow { label("Last active"); Text(lastActive.formatted(date: .abbreviated, time: .shortened)) }
            }
            if group.kind == .worktree {
                GridRow { label("Merged into default"); yesNo(git.mergedIntoDefault) }
                GridRow { label("Remote branch gone"); yesNo(git.upstreamGone) }
                GridRow { label("Uncommitted changes"); yesNo(git.hasUncommittedChanges, warnWhenTrue: true) }
                GridRow {
                    label("Commits on no remote")
                    yesNo(git.hasUnpushedCommits.map { $0 && git.mergedIntoDefault != true }, warnWhenTrue: true)
                }
            }
        }
        .font(.callout)
    }

    private var bucketGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text("")
                label("du says").gridColumnAlignment(.trailing)
                label("Frees alone").gridColumnAlignment(.trailing)
                label("Files").gridColumnAlignment(.trailing)
            }
            ForEach(group.buckets, id: \.kind) { bucket in
                GridRow {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(bucket.kind.color).frame(width: 10, height: 10)
                        Text(bucket.kind.title)
                    }
                    Text(bytes(bucket.apparentBytes)).foregroundStyle(.secondary)
                    Text(bytes(bucket.freeableAloneBytes)).fontWeight(.medium)
                    Text(bucket.fileCount.formatted()).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout.monospacedDigit())
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    /// Nil means the scan skipped the check because it could not change the status.
    private func yesNo(_ value: Bool?, warnWhenTrue: Bool = false) -> some View {
        guard let value else {
            return Text("Not checked, in use recently").foregroundStyle(.secondary)
        }
        return Text(value ? "Yes" : "No")
            .foregroundStyle(value && warnWhenTrue ? .orange : .primary)
    }
}

struct PlanBar: View {
    let report: Report
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        HStack(spacing: 10) {
            if model.selection.isEmpty {
                Text("Nothing selected. Pick stale worktrees to start a cleanup plan.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.selection.count) selected")
                Text("frees \(bytes(report.freeableBytes(selection: model.selection)))")
                    .fontWeight(.semibold)
                Text("(du would claim \(bytes(report.apparentBytes(selection: model.selection))))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Select stale worktrees and stores") { model.selectStale() }
            Button("Clear") { model.clearSelection() }
                .disabled(model.selection.isEmpty)
            Button(model.copiedPlan ? "Copied" : "Copy cleanup commands") { model.copyPlan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty)
        }
        .padding(10)
    }
}
