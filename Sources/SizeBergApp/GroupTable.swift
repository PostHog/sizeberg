import SizeBergCore
import SwiftUI

/// One table row: an item, or a parent row with items below it. A parent is a main checkout with its
/// worktrees, or an agent waste section with its items. It sums up its items, since it is never deleted itself.
struct ItemRow: Identifiable {
    let group: GroupReport
    /// Items shown below a parent row. Nil for a plain row.
    var children: [ItemRow]?
    /// Frees-alone bytes, or for a parent what its listed items free together.
    let freesBytes: Int64
    let duBytes: Int64
    /// Cleanup value, or the sum of the items' values for a parent.
    let cleanupKey: Int64
    /// Stale worktrees under a main checkout, items in use under an agent waste section.
    let flaggedCount: Int
    /// Sorts working agents first, then by how recently one worked. Zero when none did.
    var agentKey: Double {
        guard let agent = group.agent else { return 0 }
        return agent.isWorking ? .greatestFiniteMagnitude : agent.lastActive?.timeIntervalSince1970 ?? 0
    }
    /// What trimming frees: build output and caches of the item, or of the checkout and its listed worktrees.
    let trimBytes: Int64

    var id: Int { group.id }
    var name: String { group.name }
    var typeKey: String { group.statusText }
    var isParent: Bool { children != nil }
    var isRepository: Bool { isParent && group.kind == .mainCheckout }
    var isSection: Bool { isParent && group.isSectionItem }

    init(group: GroupReport) {
        self.group = group
        children = nil
        freesBytes = group.freeableAloneBytes
        duBytes = group.apparentBytes
        cleanupKey = group.cleanupSortKey
        flaggedCount = 0
        trimBytes = group.trimBytes
    }

    init(parent: GroupReport, items: [GroupReport], report: Report) {
        group = parent
        children = items.map { ItemRow(group: $0) }
        // Together, not a sum: blocks shared only among these items free once all of them go.
        // A section counts only the items that can go; the rest are in use or shown for their size.
        let freeable = parent.isSectionItem ? items.filter(\.selectable) : items
        freesBytes = report.freeableBytes(selection: Set(freeable.map(\.id)))
        duBytes = items.reduce(0) { $0 + $1.apparentBytes }
        cleanupKey = items.reduce(0) { $0 + max(0, $1.cleanupSortKey) }
        flaggedCount = parent.isSectionItem ? items.filter { $0.inUse == true }.count : items.filter(\.goesWithStale).count
        trimBytes = items.reduce(parent.trimBytes) { $0 + $1.trimBytes }
    }

    /// Rows for the visible groups, with worktrees under their main checkout and agent waste under
    /// its section when `nested` is on.
    static func rows(visible: [GroupReport], report: Report, nested: Bool) -> [ItemRow] {
        guard nested else { return visible.map { ItemRow(group: $0) } }
        let visibleIDs = Set(visible.map(\.id))
        var placed = Set<Int>()
        var rows: [ItemRow] = []
        for main in report.groups where main.kind == .mainCheckout {
            let worktrees = report.worktrees(of: main).filter { visibleIDs.contains($0.id) }
            placed.formUnion(worktrees.map(\.id))
            if !worktrees.isEmpty {
                rows.append(ItemRow(parent: main, items: worktrees, report: report))
                placed.insert(main.id)
            } else if visibleIDs.contains(main.id) {
                rows.append(ItemRow(group: main))
                placed.insert(main.id)
            }
        }
        for section in AgentWasteSection.allCases {
            let items = visible.filter { $0.section == section }
            guard !items.isEmpty, let parent = report.sectionItem(section) else { continue }
            rows.append(ItemRow(parent: parent, items: items, report: report))
            placed.formUnion(items.map(\.id))
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
        let rows = sorted(ItemRow.rows(visible: model.visibleGroups(in: report), report: report, nested: model.groupItems))
        Table(of: ItemRow.self, selection: $model.focusedID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.group.name)
                        .fontWeight(row.isParent ? .semibold : .regular)
                        .lineLimit(1)
                    if row.children == nil, row.group.kind == .worktree {
                        BranchLabel(group: row.group)
                    } else {
                        Text(subtitle(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 190, ideal: 230)
            TableColumn("Type", value: \.typeKey) { row in
                StatusBadge(group: row.group)
            }
            .width(min: 96, ideal: 112)
            TableColumn("Agent", value: \.agentKey) { row in
                AgentCell(agent: row.group.agent)
            }
            .width(min: 80, ideal: 96)
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
                        if row.isParent {
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
        } else if row.isSection, let section = row.group.section {
            let deletable = report.items(in: section).filter(\.selectable)
            if !deletable.isEmpty {
                Button("Select All") { model.selectDeletable(in: section) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(deletable.allSatisfy { model.selection.contains($0.id) })
                    .help("Select the \(deletable.count) \(deletable.count == 1 ? "item" : "items") here that can go. Items in use and size-only items stay.")
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
        if row.isSection {
            return "\(count) \(count == 1 ? "item" : "items")" + (row.flaggedCount > 0 ? " · \(row.flaggedCount) in use" : "")
        }
        return "\(count) \(count == 1 ? "worktree" : "worktrees")" + (row.flaggedCount > 0 ? " · \(row.flaggedCount) stale" : "")
    }

    @ViewBuilder
    private func cleanupCell(_ row: ItemRow) -> some View {
        if let children = row.children {
            CleanupSummaryCell(scores: children.compactMap { $0.group.cleanupScore() })
        } else if let score = row.group.cleanupScore() {
            CleanupCell(score: score)
        }
    }
}
