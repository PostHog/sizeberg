import SizeBergCore
import SwiftUI

/// Every item with what deleting it frees, ranked by cleanup value.
struct GroupTable: View {
    let report: Report
    @Environment(ScanModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\GroupReport.cleanupSortKey, order: .reverse)]

    var body: some View {
        @Bindable var model = model
        let rows = model.visibleGroups(in: report).sorted(using: sortOrder)
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
            .width(min: 140, ideal: 180)
            TableColumn("Type", value: \.statusSortKey) { group in
                StatusBadge(group: group)
            }
            .width(min: 96, ideal: 104)
            TableColumn("Cleanup", value: \.cleanupSortKey) { group in
                if let score = group.cleanupScore() {
                    CleanupCell(score: score)
                }
            }
            .width(min: 110, ideal: 140)
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
        }
    }
}
