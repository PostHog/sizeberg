import SizeBergCore
import SwiftUI

/// Confirms a cleanup, then shows each step as it runs and what it freed.
/// Deleted files skip the Trash, so the sheet names every item and its command before anything runs.
struct CleanupSheet: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        if let session = model.cleanup {
            VStack(alignment: .leading, spacing: 16) {
                header(session)
                List {
                    if !session.deleteItems.isEmpty {
                        Section {
                            ForEach(session.deleteItems) { item in
                                StepRow(item: item)
                            }
                        }
                    }
                    if !session.trimItems.isEmpty {
                        Section {
                            ForEach(session.trimItems) { item in
                                StepRow(item: item)
                            }
                        } header: {
                            Text("Build output and caches only, in \(session.trimItems.count) items that stay")
                        }
                    }
                    if !session.manual.isEmpty {
                        Section("Not included") {
                            ForEach(session.manual) { manual in
                                LabeledContent(manual.name) {
                                    Text(manual.reason).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 220, idealHeight: 320)
                footer(session)
            }
            .padding(20)
            .frame(width: 620)
            .interactiveDismissDisabled(session.phase == .running)
        }
    }

    @ViewBuilder
    private func header(_ session: CleanupSession) -> some View {
        switch session.phase {
        case .confirm:
            VStack(alignment: .leading, spacing: 6) {
                Text(title(session))
                    .font(.title2.weight(.semibold))
                Text("This frees about \(bytes(session.expectedBytes)). Deleted files do not go to the Trash and cannot be restored.")
                    .foregroundStyle(.secondary)
                if !session.deleteItems.isEmpty, !session.trimItems.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                        GridRow {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                            Text("Deleted whole: \(deleteCount(session)) \(deleteCount(session) == 1 ? "item" : "items")")
                            Text(bytes(session.deleteBytes)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                        GridRow {
                            Image(systemName: "hammer").foregroundStyle(.secondary)
                            Text("Build output only: \(session.trimItems.count) items that stay")
                            Text(bytes(session.trimBytes)).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 2)
                }
                if !session.deleteItems.isEmpty {
                    Text("Each worktree and folder is checked again first. A worktree with uncommitted changes or commits no remote has is skipped, and so is a folder that changed since the scan."
                         + (session.keptWithLocalWork > 0 ? " \(session.keptWithLocalWork) stale \(session.keptWithLocalWork == 1 ? "worktree" : "worktrees") with local work \(session.keptWithLocalWork == 1 ? "is" : "are") not in this plan." : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !session.trimItems.isEmpty {
                    Text("Build output and caches go from items that stay: your source, commits and dependencies are not touched, and the next build puts the folders back. Folders that hold files git tracks stay, and so do folders under 1 MB. Stop dev servers and builds first.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Cleaning up").font(.title2.weight(.semibold))
            }
        case .finished:
            VStack(alignment: .leading, spacing: 6) {
                Text("Freed \(bytes(session.freedBytes))")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("The scan expected \(bytes(session.doneExpectedBytes)) for the steps that ran. Other programs writing at the same time move the free space too.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deleteCount(_ session: CleanupSession) -> Int {
        session.deleteItems.reduce(0) { $0 + $1.step.groupIDs.count }
    }

    private func title(_ session: CleanupSession) -> String {
        let count = deleteCount(session)
        let items = "\(count) \(count == 1 ? "item" : "items")"
        let trims = session.trimItems.count
        switch (count, trims) {
        case (_, 0): return "Delete \(items)?"
        case (0, _): return "Delete build output in \(trims) items?"
        default: return "Delete \(items), and build output in \(trims) others?"
        }
    }

    @ViewBuilder
    private func footer(_ session: CleanupSession) -> some View {
        HStack {
            Spacer()
            switch session.phase {
            case .confirm:
                if model.isScanning {
                    // Says why Delete waits, instead of a silently disabled button.
                    ProgressView().controlSize(.small)
                    Text("Waiting for the scan to finish")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button("Cancel", role: .cancel) { model.closeCleanup() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    model.runCleanup()
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(session.items.isEmpty || model.isScanning)
            case .running:
                Button("Done") {}
                    .disabled(true)
            case .finished:
                Button("Done") { model.closeCleanup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}

private struct StepRow: View {
    let item: CleanupSession.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            statusIcon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(commandText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(messageColor)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            Text(bytes(item.step.expectedBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            // Not a circle: an empty circle reads as an unticked box that could be ticked.
            Image(systemName: item.step.isTrim ? "hammer" : "trash").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .finished(.done):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .finished(.partlyDone):
            Image(systemName: "checkmark.circle").foregroundStyle(GroupReport.localWorkColor)
        case .finished(.skipped):
            Image(systemName: "minus.circle.fill").foregroundStyle(GroupReport.localWorkColor)
        case .finished(.failed):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    /// Build output can be thousands of __pycache__ folders, so the row names what goes instead of listing it.
    private var commandText: String {
        let step = item.step
        return step.isTrim ? folderSummary(step.folders, names: 4) : step.command
    }

    private var title: String {
        let step = item.step
        return step.groupIDs.count > 1 ? "\(step.name) and \(step.groupIDs.count - 1) more" : step.name
    }

    private var message: String? {
        switch item.status {
        case .finished(.skipped(let reason)): return "Skipped: \(reason)"
        case .finished(.partlyDone(let reason)): return reason
        case .finished(.failed(let output)): return output
        default: return nil
        }
    }

    private var messageColor: Color {
        if case .finished(.failed) = item.status {
            return .red
        }
        return GroupReport.localWorkColor
    }
}
