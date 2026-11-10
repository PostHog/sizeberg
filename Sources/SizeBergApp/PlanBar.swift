import SizeBergCore
import SwiftUI

/// The cleanup plan, docked under the list: what the selection frees and the one action on it.
/// It sits on the bar material rather than floating glass, so its text stays readable over a busy table.
///
/// The size comes from the same plan the review sheet runs, so the bar never promises more than the
/// sheet: selected items the app cannot delete itself show up as "need you", with the reason.
struct PlanBar: View {
    let report: Report
    @Environment(ScanModel.self) private var model
    @State private var showsManual = false

    var body: some View {
        HStack(spacing: 12) {
            if model.selection.isEmpty {
                idle
            } else {
                selected
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    /// Nothing selected: two quick starts, with what each one frees in its label.
    @ViewBuilder
    private var idle: some View {
        Text("Select items to clean up")
            .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        let buildBytes = report.trimAllBytes
        Button("Select Build Output · \(bytes(buildBytes))") { model.selectBuildOutput() }
            .disabled(buildBytes == 0)
            .help("Build output and caches in every checkout, worktree and folder. The items stay; the next build puts these back.")
        let staleBytes = report.freeableBytes(selection: report.staleSelection)
        Button("Select Stale · \(bytes(staleBytes))") { model.selectStale() }
            // Missing worktrees free nothing but still have a prune to run.
            .disabled(report.staleSelection.isEmpty)
            .help("Worktrees quiet for 3 days with merged or remote-gone work, or quiet for 21 days, and the package stores that hold their dependencies.")
    }

    @ViewBuilder
    private var selected: some View {
        let plan = CleanupRunner.plan(for: report, selection: model.selection)
        let deleteBytes = ScanModel.expectedBytes(of: plan.steps, in: report)
        let itemCount = Set(plan.steps.flatMap(\.groupIDs) + plan.manual.map(\.id)).count
        Button {
            model.clearSelection()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Clear the selection (Esc)")
        .accessibilityLabel("Clear selection")
        summary(itemCount: itemCount, deleteBytes: deleteBytes, manual: plan.manual)
        Spacer(minLength: 12)
        Menu {
            Button("Copy Commands") { model.copyPlan() }
        } label: {
            Image(systemName: model.copiedPlan ? "checkmark" : "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: copy the cleanup commands to run them yourself")
        .accessibilityLabel(model.copiedPlan ? "Commands copied" : "More actions")
        Button("Delete \(bytes(deleteBytes))…", role: .destructive) { model.prepareCleanup() }
            .buttonStyle(.borderedProminent)
            .disabled(plan.steps.isEmpty || model.cleanup?.phase == .running)
            .help("Review what gets deleted first. Nothing is deleted until you confirm, and deleted files skip the Trash.")
    }

    @ViewBuilder
    private func summary(itemCount: Int, deleteBytes: Int64, manual: [GroupReport]) -> some View {
        let items = "\(itemCount) \(itemCount == 1 ? "item" : "items")"
        let size = manual.isEmpty
            ? "about \(bytes(deleteBytes))"
            : "\(bytes(deleteBytes)) of \(bytes(report.freeableBytes(selection: model.selection)))"
        Text("\(items) · \(size)")
            .font(.headline)
            .monospacedDigit()
            .help("du would count \(bytes(report.apparentBytes(selection: model.selection))). Files that share blocks with copies outside the selection free nothing.")
        if !manual.isEmpty {
            Button {
                showsManual = true
            } label: {
                Label("\(manual.count) need you", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(GroupReport.localWorkColor)
            }
            .buttonStyle(.plain)
            .help("The app does not delete these itself")
            .popover(isPresented: $showsManual, arrowEdge: .top) {
                manualList(manual)
            }
        }
    }

    private func manualList(_ manual: [GroupReport]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not deleted by the app")
                .font(.headline)
            ForEach(manual) { group in
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                    Text(CleanupRunner.reasonNotIncluded(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Copy Commands") { model.copyPlan() }
                Spacer()
                Button("Deselect These") {
                    model.selection.subtract(manual.map(\.id))
                    showsManual = false
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 300)
    }
}
