import SizeBergCore
import SwiftUI

/// Trailing inspector: the focused item, or a hint to pick one.
struct InspectorView: View {
    let report: Report
    @Environment(ScanModel.self) private var model

    var body: some View {
        if let id = model.focusedID, let group = report.group(id) {
            GroupDetail(report: report, group: group)
        } else {
            ContentUnavailableView(
                "No item selected",
                systemImage: "cursorarrow.click",
                description: Text("Select a row or a tile to see what it holds and how to clean it up.")
            )
        }
    }
}

struct GroupDetail: View {
    let report: Report
    let group: GroupReport
    @Environment(ScanModel.self) private var model

    var body: some View {
        Form {
            Section {
                header
                if let score = group.cleanupScore() {
                    LabeledContent("Cleanup value") {
                        CleanupCell(score: score, isInline: true)
                    }
                }
            }
            let worktrees = report.worktrees(of: group)
            if !worktrees.isEmpty {
                Section("Worktrees") {
                    worktreeSummary(worktrees)
                }
            }
            if group.kind != .system, group.apparentBytes > 0 {
                Section(group.kind == .mainCheckout ? "What deleting the checkout would free" : "What deleting frees") {
                    SizeBreakdown(report: report, group: group)
                }
            }
            if let git = group.git {
                Section("Git") {
                    gitFacts(git)
                }
            }
            if !group.buckets.isEmpty {
                Section("Inside") {
                    bucketGrid
                }
            }
            if group.cleanupCommand != nil || group.note != nil {
                Section("Clean up") {
                    if let note = group.note {
                        Text(note)
                            .foregroundStyle(.secondary)
                    }
                    if let command = group.cleanupCommand {
                        commandRow(command)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                StatusBadge(group: group)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(displayPath(group.path))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Show in Finder", systemImage: "folder") { model.reveal(group.path) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            if group.selectable {
                Toggle("In cleanup plan", isOn: model.binding(for: group.id))
            }
        }
    }

    /// The checkout stays; its worktrees are what can go. Together they free more than each alone,
    /// because blocks shared only among them free once all of them go.
    @ViewBuilder
    private func worktreeSummary(_ worktrees: [GroupReport]) -> some View {
        let ids = Set(worktrees.map(\.id))
        let stale = worktrees.filter(\.isStale)
        LabeledContent("Worktrees", value: "\(worktrees.count), \(stale.count) stale")
        LabeledContent("All together free") {
            Text(bytes(report.freeableBytes(selection: ids))).monospacedDigit().fontWeight(.medium)
        }
        LabeledContent("Each alone, added up") {
            Text(bytes(worktrees.reduce(0) { $0 + $1.freeableAloneBytes })).monospacedDigit()
        }
        if !stale.isEmpty {
            LabeledContent("Stale ones together free") {
                Text(bytes(report.freeableBytes(selection: Set(stale.map(\.id))))).monospacedDigit()
            }
        }
        HStack {
            Spacer()
            if !stale.isEmpty {
                Button("Select stale") { model.selection.formUnion(stale.map(\.id)) }
            }
            Button("Select all") { model.selection.formUnion(ids) }
        }
    }

    @ViewBuilder
    private func gitFacts(_ git: GitInfo) -> some View {
        if let branch = git.branch {
            LabeledContent("Branch") {
                Text(branch)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let lastActive = git.lastActive {
            LabeledContent("Last active", value: lastActive.formatted(date: .abbreviated, time: .shortened))
        }
        if group.kind == .worktree {
            LabeledContent("Merged into default") { yesNo(git.mergedIntoDefault) }
            LabeledContent("Remote branch gone") { yesNo(git.upstreamGone) }
            LabeledContent("Uncommitted changes") { yesNo(git.hasUncommittedChanges, warnWhenTrue: true) }
            LabeledContent("Commits on no remote") {
                yesNo(git.hasUnpushedCommits.map { $0 && git.mergedIntoDefault != true }, warnWhenTrue: true)
            }
        }
    }

    private var bucketGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
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

    private func commandRow(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc") { model.copy(command) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy command")
        }
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
            .foregroundStyle(value && warnWhenTrue ? AnyShapeStyle(GroupReport.localWorkColor) : AnyShapeStyle(.primary))
    }
}
