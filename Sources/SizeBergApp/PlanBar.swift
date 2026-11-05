import SizeBergCore
import SwiftUI

/// The cleanup plan, docked under the list: what the plan frees and the actions on it.
/// It sits on the bar material rather than floating glass, so its text stays readable over a busy table.
struct PlanBar: View {
    let report: Report
    @Environment(ScanModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            summary
            Spacer(minLength: 12)
            actions
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.selection.isEmpty {
            Button("Select Build Output") { model.selectBuildOutput() }
                .disabled(report.trimAllBytes == 0)
                .help("Select build output and caches in every checkout, worktree and folder. The items stay.")
            Button("Select Stale") { model.selectStale() }
                .buttonStyle(.borderedProminent)
                .help("Select stale worktrees and the package stores")
        } else {
            Button("Clear") { model.clearSelection() }
            Button(model.copiedPlan ? "Copied" : "Copy Commands") { model.copyPlan() }
                .help("Copy the cleanup commands to run them yourself")
            Button("Clean Up…", role: .destructive) { model.prepareCleanup() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.cleanup?.phase == .running)
                .help("Review the cleanup, then run it")
        }
    }

    @ViewBuilder
    private var summary: some View {
        if model.selection.isEmpty {
            HStack(spacing: 28) {
                figure(bytes(report.freeableBytes(selection: report.staleSelection)), "stale worktrees and stores free")
                figure(bytes(report.trimAllBytes), "build output and caches free, the next build puts them back")
            }
        } else {
            let count = model.selection.count
            figure(
                "frees \(bytes(report.freeableBytes(selection: model.selection)))",
                "\(count) selected · du would claim \(bytes(report.apparentBytes(selection: model.selection)))"
            )
        }
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
