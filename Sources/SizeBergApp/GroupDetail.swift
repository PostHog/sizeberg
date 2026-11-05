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
            if group.kind == .buildOutput {
                Section("Where it is") {
                    buildOutputHolders
                }
            }
            if group.kind != .system, group.kind != .buildOutput, group.apparentBytes > 0 {
                Section(group.kind == .mainCheckout ? "What deleting the checkout would free" : "What deleting frees") {
                    SizeBreakdown(report: report, group: group)
                }
            }
            let trimBuckets = group.trimmableBuckets
            if !trimBuckets.isEmpty {
                Section {
                    ForEach(trimBuckets, id: \.kind) { bucket in
                        trimRow(bucket)
                    }
                } header: {
                    Text("Build output and caches in this item")
                } footer: {
                    Text("Select “Build output and caches” in the list to delete these in every item at once. The next build or tool run puts them back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            if !group.paths.isEmpty {
                pathRow
            }
            if group.selectable {
                Toggle("In cleanup plan", isOn: model.binding(for: group.id))
            }
        }
    }

    private var pathRow: some View {
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
    }

    /// The checkout stays; its worktrees are what can go. Together they free more than each alone,
    /// because blocks shared only among them free once all of them go.
    @ViewBuilder
    private func worktreeSummary(_ worktrees: [GroupReport]) -> some View {
        let ids = Set(worktrees.map(\.id))
        let stale = worktrees.filter(\.goesWithStale)
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
        // No "select all": deleting every worktree, active ones too, is rarely what anyone wants.
        if !stale.isEmpty {
            HStack {
                Spacer()
                Button("Select Stale") { model.selectStale(of: group) }
            }
        }
    }

    /// The items that hold the most build output, for the build output item.
    @ViewBuilder
    private var buildOutputHolders: some View {
        let holders = report.groups.filter { $0.trimBytes > 0 }.sorted { $0.trimBytes > $1.trimBytes }
        ForEach(holders.prefix(Self.listedHolders), id: \.id) { holder in
            LabeledContent {
                Text(bytes(holder.trimBytes)).monospacedDigit()
            } label: {
                Text(holder.name)
                Text(holder.trimmableBuckets.map(\.kind.title).joined(separator: ", "))
            }
        }
        if holders.count > Self.listedHolders {
            Text("and \(holders.count - Self.listedHolders) more, \(bytes(holders.dropFirst(Self.listedHolders).reduce(0) { $0 + $1.trimBytes })) together")
                .foregroundStyle(.secondary)
        }
        let leftOut = report.buildOutputLeftOut
        if let text = leftOutText(smallCount: leftOut.smallCount, smallBytes: leftOut.smallBytes, trackedCount: leftOut.trackedCount) {
            Text(text + ". Thousands of small folders free little, and each makes the next build slower.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private static let listedHolders = 12

    private func trimRow(_ bucket: BucketReport) -> some View {
        let folders = (bucket.folders ?? []).map(\.path)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(bucket.kind.color)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bucket.kind.title)
                    Text(folderSummary(folders))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let leftOut = leftOutText(
                        smallCount: bucket.smallFolderCount ?? 0, smallBytes: bucket.smallFolderBytes ?? 0,
                        trackedCount: bucket.trackedFolderCount ?? 0
                    ) {
                        Text(leftOut)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(bytes(bucket.foldersFreeBytes ?? bucket.freeableAloneBytes))
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            DisclosureGroup("Folders") {
                // A name that repeats, like __pycache__, shows once with its count; a single folder shows its path.
                let names = foldersByName(folders)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names.prefix(Self.listedNames), id: \.name) { entry in
                        HStack {
                            Text(entry.paths.count == 1 ? relativePath(entry.paths[0]) : entry.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            if entry.paths.count > 1 {
                                Text("in \(roughCount(entry.paths.count)) places")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    }
                    if names.count > Self.listedNames {
                        Text("and \(names.count - Self.listedNames) more names")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    private static let listedNames = 20

    private func relativePath(_ folder: String) -> String {
        let root = group.path + "/"
        return folder.hasPrefix(root) ? String(folder.dropFirst(root.count)) : displayPath(folder)
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
        if let agent = group.agent {
            LabeledContent("Coding agent") {
                if agent.isWorking {
                    Text("Working now").foregroundStyle(GroupReport.localWorkColor)
                } else if let last = agent.lastActive {
                    Text(last.formatted(.relative(presentation: .named)))
                }
            }
        }
        if group.kind == .worktree {
            LabeledContent("Merged into default") { yesNo(git.mergedIntoDefault) }
            if let squash = git.squashMerge {
                // A squash merge rewrote the branch's commits into one, so git alone calls them unmerged.
                LabeledContent("Merged as") {
                    Text(squash.hasPrefix("#") ? "pull request \(squash)" : "squash commit \(squash)")
                        .textSelection(.enabled)
                }
            }
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
