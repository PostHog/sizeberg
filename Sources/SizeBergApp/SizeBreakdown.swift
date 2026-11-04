import SizeBergCore
import SwiftUI

/// Splits what du counts for one item into what deleting it alone frees, what it shares with
/// other items, and copies du counts more than once.
struct SizeBreakdown: View {
    private struct Part: Identifiable {
        var title: String
        var detail: String
        var bytes: Int64
        var color: Color

        var id: String { title }
    }

    let report: Report
    let group: GroupReport

    var body: some View {
        let alone = group.freeableAloneBytes
        let shared = report.sharedWithOthersBytes(group.id)
        let countedAgain = max(0, group.apparentBytes - alone - shared)
        let parts = [
            Part(title: "Frees alone", detail: "Held only by this item.", bytes: alone, color: .accentColor),
            Part(title: "Shared", detail: "Also held by other folders or caches. Frees only when every copy goes.", bytes: shared, color: TileBuilder.sharedColor),
            Part(title: "Counted again by du", detail: "Copies of the same data inside this item. The disk holds it once.", bytes: countedAgain, color: Color.secondary.opacity(0.35)),
        ].filter { $0.bytes > 0 }
        let total = max(parts.reduce(0) { $0 + $1.bytes }, 1)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bytes(alone))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("freed by deleting this alone")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("du says \(bytes(group.apparentBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(parts) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, (geometry.size.width - CGFloat(parts.count - 1)) * CGFloat(part.bytes) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(parts) { part in
                    GridRow(alignment: .firstTextBaseline) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(part.color)
                            .frame(width: 10, height: 10)
                        Text(part.title)
                        Text(bytes(part.bytes))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text(part.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
        }
    }
}
