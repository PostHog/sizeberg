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
                    Section {
                        ForEach(session.items) { item in
                            StepRow(item: item)
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
                Text("Delete \(session.items.count) \(session.items.count == 1 ? "item" : "items")?")
                    .font(.title2.weight(.semibold))
                Text("This frees about \(bytes(session.expectedBytes)). Deleted files do not go to the Trash and cannot be restored.")
                    .foregroundStyle(.secondary)
                Text("Each worktree is checked again first. One with uncommitted changes or commits no remote has is skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                Text("The scan expected \(bytes(session.expectedBytes)) for the steps that ran. Other programs writing at the same time move the free space too.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func footer(_ session: CleanupSession) -> some View {
        HStack {
            Spacer()
            switch session.phase {
            case .confirm:
                Button("Cancel", role: .cancel) { model.closeCleanup() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete \(session.items.count) \(session.items.count == 1 ? "Item" : "Items")", role: .destructive) {
                    model.runCleanup()
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(session.items.isEmpty)
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
                Text(item.step.name)
                Text(item.step.command)
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
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .finished(.done):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .finished(.skipped):
            Image(systemName: "minus.circle.fill").foregroundStyle(GroupReport.localWorkColor)
        case .finished(.failed):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var message: String? {
        switch item.status {
        case .finished(.skipped(let reason)): return "Skipped: \(reason)"
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
