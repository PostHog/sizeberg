import SizeBergCore
import SwiftUI

/// One table row: an item, or a main checkout with its worktrees below it.
/// A main checkout row sums up its worktrees, since the checkout itself is never deleted.
struct ItemRow: Identifiable {
    let group: GroupReport
    /// Worktrees shown below a main checkout. Nil for a plain row.
    var children: [ItemRow]?
    /// Frees-alone bytes, or for a main checkout what its listed worktrees free together.
    let freesBytes: Int64
    let duBytes: Int64
    /// Cleanup value, or the sum of the worktrees' values for a main checkout.
    let cleanupKey: Int64
    let staleCount: Int
    /// What trimming frees: build output and caches of the item, or of the checkout and its listed worktrees.
    let trimBytes: Int64

    var id: Int { group.id }
    var name: String { group.name }
    var typeKey: String { group.statusText }
    var isRepository: Bool { children != nil }

    init(group: GroupReport) {
        self.group = group
        children = nil
        freesBytes = group.freeableAloneBytes
        duBytes = group.apparentBytes
        cleanupKey = group.cleanupSortKey
        staleCount = 0
        trimBytes = group.trimBytes
    }

    init(repository: GroupReport, worktrees: [GroupReport], report: Report) {
        group = repository
        children = worktrees.map { ItemRow(group: $0) }
        // Together, not a sum: blocks shared only among these worktrees free once all of them go.
        freesBytes = report.freeableBytes(selection: Set(worktrees.map(\.id)))
        duBytes = worktrees.reduce(0) { $0 + $1.apparentBytes }
        cleanupKey = worktrees.reduce(0) { $0 + max(0, $1.cleanupSortKey) }
        staleCount = worktrees.filter(\.goesWithStale).count
        trimBytes = worktrees.reduce(repository.trimBytes) { $0 + $1.trimBytes }
    }

    /// Rows for the visible groups, with worktrees under their main checkout when `nested` is on.
    static func rows(visible: [GroupReport], report: Report, nested: Bool) -> [ItemRow] {
        guard nested else { return visible.map { ItemRow(group: $0) } }
        let visibleIDs = Set(visible.map(\.id))
        var placed = Set<Int>()
        var rows: [ItemRow] = []
        for main in report.groups where main.kind == .mainCheckout {
            let worktrees = report.worktrees(of: main).filter { visibleIDs.contains($0.id) }
            placed.formUnion(worktrees.map(\.id))
            if !worktrees.isEmpty {
                rows.append(ItemRow(repository: main, worktrees: worktrees, report: report))
                placed.insert(main.id)
            } else if visibleIDs.contains(main.id) {
                rows.append(ItemRow(group: main))
                placed.insert(main.id)
            }
        }
        rows += visible.filter { !placed.contains($0.id) }.map { ItemRow(group: $0) }
        return rows
    }
}

/// Every item with what deleting it frees, and what Trim All frees in it. Worktrees sit under their main checkout.
struct GroupTable: View {
    let report: Report
    @Environment(ScanModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ItemRow.cleanupKey, order: .reverse)]

    var body: some View {
        @Bindable var model = model
        let rows = sorted(ItemRow.rows(visible: model.visibleGroups(in: report), report: report, nested: model.groupWorktrees))
        Table(of: ItemRow.self, selection: $model.focusedID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.group.name)
                        .fontWeight(row.isRepository ? .semibold : .regular)
                        .lineLimit(1)
                    Text(subtitle(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 190, ideal: 230)
            TableColumn("Type", value: \.typeKey) { row in
                StatusBadge(group: row.group)
            }
            .width(min: 96, ideal: 112)
            TableColumn("Cleanup", value: \.cleanupKey) { row in
                cleanupCell(row)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Frees if deleted", value: \.freesBytes) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    deleteToggle(row)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 1) {
                        // Container disks are listed for context; the scan does not split them into removable parts.
                        Text(row.group.kind == .system ? "n/a" : bytes(row.freesBytes))
                            .monospacedDigit()
                            .fontWeight(.medium)
                        if row.isRepository {
                            Text("together")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 170, ideal: 190)
            TableColumn("Build output", value: \.trimBytes) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.trimBytes > 0 ? bytes(row.trimBytes) : "–")
                        .monospacedDigit()
                        .foregroundStyle(row.trimBytes > 0 ? .secondary : .tertiary)
                    if row.isRepository, row.trimBytes > 0 {
                        Text("with worktrees")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Build output and caches in this item. Select “Build output and caches” to delete them in every item.")
            }
            .width(min: 80, ideal: 100)
            TableColumn("du says", value: \.duBytes) { row in
                Text(bytes(row.duBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)
        } rows: {
            ForEach(rows) { row in
                if let children = row.children {
                    DisclosureTableRow(row, isExpanded: expansion(for: row.id)) {
                        ForEach(children) { child in
                            TableRow(child)
                        }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
    }

    /// Sorts repositories and the worktrees inside them by the same column.
    private func sorted(_ rows: [ItemRow]) -> [ItemRow] {
        rows.map { row in
            var sortedRow = row
            sortedRow.children = row.children?.sorted(using: sortOrder)
            return sortedRow
        }
        .sorted(using: sortOrder)
    }

    private func expansion(for id: Int) -> Binding<Bool> {
        // Searching or a cleanup filter is about worktrees, so open every repository then.
        let forceOpen = !model.searchText.isEmpty || model.filter == .stale || model.filter == .plan
        return Binding(
            get: { forceOpen || !model.collapsedRepositories.contains(id) },
            set: { isOpen in
                if isOpen {
                    model.collapsedRepositories.remove(id)
                } else {
                    model.collapsedRepositories.insert(id)
                }
            }
        )
    }

    @ViewBuilder
    private func deleteToggle(_ row: ItemRow) -> some View {
        if row.isRepository {
            // A checkbox here would read as deleting the repository. Only its stale worktrees can be picked at once.
            let stale = report.worktrees(of: row.group).filter(\.goesWithStale)
            if !stale.isEmpty {
                // Table rows draw plain buttons as bare text; the border makes it read as a button.
                Button("Select Stale") { model.selectStale(of: row.group) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(stale.allSatisfy { model.selection.contains($0.id) })
                    .help("Select the \(stale.count) stale \(stale.count == 1 ? "worktree" : "worktrees") of \(row.name). The checkout and active worktrees stay.")
            }
        } else {
            Toggle("", isOn: model.binding(for: row.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!row.group.selectable)
                // A main checkout or a container disk is never deleted from here; an empty box would suggest it is.
                .opacity(row.group.selectable ? 1 : 0)
                .help("Delete \(row.name)")
        }
    }

    private func subtitle(_ row: ItemRow) -> String {
        if row.group.kind == .buildOutput {
            let count = report.trimmableIDs.count
            return "In \(count) \(count == 1 ? "item" : "checkouts, worktrees and folders") · items stay"
        }
        guard let children = row.children else { return row.group.subtitle }
        let count = children.count
        return "\(count) \(count == 1 ? "worktree" : "worktrees")" + (row.staleCount > 0 ? " · \(row.staleCount) stale" : "")
    }

    @ViewBuilder
    private func cleanupCell(_ row: ItemRow) -> some View {
        if row.isRepository {
            VStack(alignment: .leading, spacing: 3) {
                CleanupMeter(weightedBytes: row.cleanupKey)
                Text("sum of its worktrees")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let score = row.group.cleanupScore() {
            CleanupCell(score: score)
        }
    }
}
