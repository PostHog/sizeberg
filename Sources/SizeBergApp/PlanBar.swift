import SizeBergCore
import SwiftUI

/// The cleanup plan, floating on glass over the list: what the selection frees and the actions on it.
struct PlanBar: View {
    let report: Report
    @Environment(ScanModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                summary
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                if model.selection.isEmpty {
                    Button("Select stale worktrees and stores") { model.selectStale() }
                        .buttonStyle(.glassProminent)
                } else {
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(.glass)
                    Button(model.copiedPlan ? "Copied" : "Copy cleanup commands") { model.copyPlan() }
                        .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(.bottom, 14)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var summary: some View {
        if model.selection.isEmpty {
            let stale = report.groups.filter { $0.git?.status == .stale }.count
            HStack(spacing: 6) {
                Text("\(stale) stale worktrees")
                    .fontWeight(.medium)
                Text("with their stores free \(bytes(report.freeableBytes(selection: report.staleSelection)))")
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Text("\(model.selection.count) selected")
                    .foregroundStyle(.secondary)
                Text("frees \(bytes(report.freeableBytes(selection: model.selection)))")
                    .fontWeight(.semibold)
                Text("du would claim \(bytes(report.apparentBytes(selection: model.selection)))")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
    }
}
