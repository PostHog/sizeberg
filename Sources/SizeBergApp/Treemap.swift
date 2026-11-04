import SizeBergCore
import SwiftUI

/// Squarified treemap layout (Bruls, Huizing, van Wijk). Values must be sorted largest first.
enum Squarify {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 1, rect.height > 1 else {
            return values.map { _ in .zero }
        }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var remaining = rect
        var row: [Double] = []
        var index = 0
        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            let candidate = row + [areas[index]]
            if row.isEmpty || worstRatio(candidate, side: side) <= worstRatio(row, side: side) {
                row = candidate
                index += 1
                continue
            }
            let placed = place(row, in: remaining)
            result += placed.rects
            remaining = placed.rest
            row = []
        }
        if !row.isEmpty {
            result += place(row, in: remaining).rects
        }
        return result
    }

    private static func worstRatio(_ row: [Double], side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else {
            return .infinity
        }
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    private static func place(_ row: [Double], in rect: CGRect) -> (rects: [CGRect], rest: CGRect) {
        let sum = CGFloat(row.reduce(0, +))
        if rect.width >= rect.height {
            let width = min(rect.width, sum / max(rect.height, 1))
            var y = rect.minY
            let rects = row.map { area -> CGRect in
                let height = CGFloat(area) / max(width, 1)
                defer { y += height }
                return CGRect(x: rect.minX, y: y, width: width, height: height)
            }
            return (rects, CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height))
        }
        let height = min(rect.height, sum / max(rect.width, 1))
        var x = rect.minX
        let rects = row.map { area -> CGRect in
            let width = CGFloat(area) / max(height, 1)
            defer { x += width }
            return CGRect(x: x, y: rect.minY, width: width, height: height)
        }
        return (rects, CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height))
    }
}

struct TilePart {
    var title: String
    var bytes: Int64
    var color: Color
}

struct Tile: Identifiable {
    var id: String
    var title: String
    var detail: String
    var bytes: Int64
    var groupID: Int?
    var frameColor: Color
    var parts: [TilePart]
}

enum TileBuilder {
    static let maxTiles = 70
    static let maxSharedParts = 12
    static let sharedColor = Color(red: 0.55, green: 0.40, blue: 0.85)
    static let outsideColor = Color(red: 0.45, green: 0.45, blue: 0.50)
    static let systemColor = Color(red: 0.35, green: 0.40, blue: 0.75)

    /// Tiles add up to what is really on disk: each group sized by what it frees alone,
    /// plus one tile for shared copies that only go together.
    static func tiles(for report: Report) -> [Tile] {
        var tiles: [Tile] = []
        for group in report.groups {
            if group.kind == .system {
                guard group.apparentBytes > 0 else { continue }
                tiles.append(Tile(
                    id: "group-\(group.id)",
                    title: group.name,
                    detail: group.note ?? "",
                    bytes: group.apparentBytes,
                    groupID: group.id,
                    frameColor: systemColor,
                    parts: [TilePart(title: group.name, bytes: group.apparentBytes, color: systemColor)]
                ))
                continue
            }
            guard group.freeableAloneBytes > 0 else { continue }
            tiles.append(groupTile(group))
        }
        if let shared = sharedTile(report) {
            tiles.append(shared)
        }
        if report.sharedOutsideBytes > 0 {
            tiles.append(Tile(
                id: "outside",
                title: "Shared with files outside the scan",
                detail: "Another folder or a local snapshot holds a copy, so deleting these frees nothing.",
                bytes: report.sharedOutsideBytes,
                groupID: nil,
                frameColor: outsideColor,
                parts: [TilePart(title: "Outside", bytes: report.sharedOutsideBytes, color: outsideColor)]
            ))
        }
        tiles.sort { $0.bytes > $1.bytes }
        guard tiles.count > maxTiles else { return tiles }
        let rest = tiles[(maxTiles - 1)...]
        let restBytes = rest.reduce(0) { $0 + $1.bytes }
        var kept = Array(tiles.prefix(maxTiles - 1))
        kept.append(Tile(
            id: "rest",
            title: "\(rest.count) smaller items",
            detail: "Use the table to see them.",
            bytes: restBytes,
            groupID: nil,
            frameColor: .gray,
            parts: [TilePart(title: "Smaller items", bytes: restBytes, color: .gray)]
        ))
        return kept
    }

    private static func groupTile(_ group: GroupReport) -> Tile {
        var parts = group.buckets
            .filter { $0.freeableAloneBytes > 0 }
            .map { TilePart(title: $0.kind.title, bytes: $0.freeableAloneBytes, color: $0.kind.color) }
        let inBuckets = parts.reduce(0) { $0 + $1.bytes }
        if group.freeableAloneBytes > inBuckets {
            parts.append(TilePart(title: "Shared across buckets", bytes: group.freeableAloneBytes - inBuckets, color: .gray))
        }
        parts.sort { $0.bytes > $1.bytes }
        let detail = parts.map { "\($0.title): \(bytes($0.bytes))" }.joined(separator: "\n")
        return Tile(
            id: "group-\(group.id)",
            title: group.name,
            detail: "\(group.statusText). Frees alone \(bytes(group.freeableAloneBytes)), du says \(bytes(group.apparentBytes)).\n\(detail)",
            bytes: group.freeableAloneBytes,
            groupID: group.id,
            frameColor: group.statusColor,
            parts: parts
        )
    }

    private static func sharedTile(_ report: Report) -> Tile? {
        let sets = report.sharedSets.filter { !$0.groupIDs.contains(Report.outsideGroupID) }
        let total = sets.reduce(0) { $0 + $1.bytes }
        guard total > 0 else { return nil }
        var parts = sets.prefix(maxSharedParts).map { set in
            TilePart(title: report.label(for: set), bytes: set.bytes, color: sharedColor)
        }
        let shown = parts.reduce(0) { $0 + $1.bytes }
        if total > shown {
            parts.append(TilePart(title: "Other shared sets", bytes: total - shown, color: sharedColor.opacity(0.7)))
        }
        return Tile(
            id: "shared",
            title: "Shared copy-on-write data",
            detail: "Clones that several folders hold. This frees only when every folder holding a copy goes.",
            bytes: total,
            groupID: nil,
            frameColor: sharedColor,
            parts: parts
        )
    }
}

struct TreemapView: View {
    let report: Report
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        let tiles = TileBuilder.tiles(for: report)
        VStack(alignment: .leading, spacing: 6) {
            Text("Where the real bytes are")
                .font(.headline)
            legend
            GeometryReader { geometry in
                let rects = Squarify.layout(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: geometry.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        TileView(
                            tile: tile,
                            isSelected: tile.groupID.map(model.isSelected) ?? false,
                            isFocused: tile.groupID != nil && tile.groupID == model.focusedID
                        )
                        .frame(width: max(rects[index].width, 0), height: max(rects[index].height, 0))
                        .offset(x: rects[index].minX, y: rects[index].minY)
                        .onTapGesture(count: 2) {
                            if let id = tile.groupID {
                                model.toggle(id)
                            }
                        }
                        .onTapGesture {
                            model.focusedID = tile.groupID
                        }
                    }
                }
            }
            Text("Tile size is what deleting the item alone frees. Click to inspect, double-click to add it to the cleanup plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(BucketKind.allCases, id: \.self) { kind in
                legendItem(kind.shortTitle, kind.color)
            }
            legendItem("Shared", TileBuilder.sharedColor)
        }
        .font(.caption)
    }

    private func legendItem(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }
}

struct TileView: View {
    static let headerHeight: CGFloat = 18

    let tile: Tile
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let showsHeader = size.height > 40 && size.width > 70
            let header = showsHeader ? Self.headerHeight : 0
            let inner = CGRect(x: 2, y: header + 1, width: max(size.width - 4, 0), height: max(size.height - header - 3, 0))
            let rects = Squarify.layout(tile.parts.map { Double($0.bytes) }, in: inner)
            ZStack(alignment: .topLeading) {
                ForEach(Array(tile.parts.enumerated()), id: \.offset) { index, part in
                    partView(part, rect: rects[index])
                }
                if showsHeader {
                    HStack(spacing: 4) {
                        Text(tile.title).fontWeight(.semibold).lineLimit(1)
                        Text(bytes(tile.bytes)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .frame(width: size.width, height: header)
                }
            }
        }
        .background(tile.frameColor.opacity(isSelected ? 0.55 : 0.22))
        .overlay(
            Rectangle().strokeBorder(borderColor, lineWidth: isFocused || isSelected ? 2 : 0.5)
        )
        .contentShape(Rectangle())
        .help("\(tile.title)\n\(tile.detail)")
    }

    private var borderColor: Color {
        if isFocused { return .accentColor }
        if isSelected { return .green }
        return Color.black.opacity(0.3)
    }

    @ViewBuilder
    private func partView(_ part: TilePart, rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(part.color.opacity(isSelected ? 0.95 : 0.75))
            if rect.width > 90, rect.height > 30, tile.parts.count > 1 {
                Text("\(part.title)\n\(bytes(part.bytes))")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(3)
            }
        }
        .frame(width: max(rect.width - 1, 0), height: max(rect.height - 1, 0))
        .offset(x: rect.minX, y: rect.minY)
    }
}
