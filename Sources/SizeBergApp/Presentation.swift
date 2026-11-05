import AppKit
import SizeBergCore
import SwiftUI

func bytes(_ value: Int64) -> String {
    ByteFormat.string(value)
}

/// Whole gigabytes from 10 GB up, for places with room for a glance only, like the sidebar.
func roundedBytes(_ value: Int64) -> String {
    let gigabytes = Double(value) / 1_000_000_000
    guard gigabytes >= 10 else { return bytes(value) }
    return "\(Int(gigabytes.rounded()).formatted()) GB"
}

extension BucketKind {
    var shortTitle: String {
        switch self {
        case .source: return "Source"
        case .dependencies: return "Deps"
        case .buildOutput: return "Build"
        case .caches: return "Caches"
        case .git: return "Git"
        }
    }

    var color: Color {
        switch self {
        case .source: return Color(red: 0.55, green: 0.58, blue: 0.64)
        case .dependencies: return Color(red: 0.20, green: 0.62, blue: 0.62)
        case .buildOutput: return Color(red: 0.93, green: 0.55, blue: 0.20)
        case .caches: return Color(red: 0.86, green: 0.72, blue: 0.22)
        case .git: return Color(red: 0.62, green: 0.45, blue: 0.33)
        }
    }
}

/// Folders by name, most common first: a Python tree has one __pycache__ per package.
func foldersByName(_ folders: [String]) -> [(name: String, paths: [String])] {
    Dictionary(grouping: folders) { ($0 as NSString).lastPathComponent }
        .map { (name: $0.key, paths: $0.value) }
        .sorted { ($0.paths.count, $1.name) > ($1.paths.count, $0.name) }
}

/// A short count for names that repeat a lot: 3,888 reads as "3k+".
func roughCount(_ count: Int) -> String {
    count < 1_000 ? count.formatted() : "\(count / 1_000)k+"
}

/// What a list of folders holds, like "__pycache__ in 3k+ places, .turbo, dist in 24 places and 4 more".
func folderSummary(_ folders: [String], names shown: Int = 3) -> String {
    let names = foldersByName(folders)
    let parts = names.prefix(shown).map { entry in
        entry.paths.count > 1 ? "\(entry.name) in \(roughCount(entry.paths.count)) places" : entry.name
    }
    let rest = names.count - shown
    return parts.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
}

extension GroupReport {
    var statusText: String {
        switch kind {
        case .mainCheckout: return "Main checkout"
        case .project: return "Folder"
        case .cache: return "Cache"
        case .system: return "Containers"
        case .buildOutput: return "Rebuildable"
        case .worktree:
            switch git?.status ?? .active {
            case .active: return "Worktree"
            case .stale: return "Stale"
            case .staleWithLocalWork: return "Stale, local work"
            case .missing: return "Missing"
            }
        }
    }

    var statusColor: Color {
        switch git?.status {
        case .stale: return .red
        // System orange and yellow are too light for text on their own tint; these pass 4.5:1.
        case .staleWithLocalWork: return Self.localWorkColor
        case .missing: return .secondary
        default: break
        }
        switch kind {
        case .worktree: return .blue
        case .mainCheckout: return .indigo
        case .cache: return .adaptive(light: Color(red: 0.52, green: 0.40, blue: 0.0), dark: Color(red: 0.93, green: 0.78, blue: 0.32))
        case .system: return .purple
        case .project: return .gray
        case .buildOutput: return .adaptive(light: Color(red: 0.70, green: 0.36, blue: 0.0), dark: Color(red: 0.98, green: 0.62, blue: 0.30))
        }
    }

    static let localWorkColor = Color.adaptive(light: Color(red: 0.70, green: 0.36, blue: 0.0), dark: .orange)

    var typeSymbol: String {
        switch kind {
        case .worktree: return git?.status == .missing ? "questionmark.folder" : "arrow.triangle.branch"
        case .mainCheckout: return "chevron.left.forwardslash.chevron.right"
        case .project: return "folder"
        case .cache: return "archivebox"
        case .system: return "shippingbox"
        case .buildOutput: return "hammer"
        }
    }

    var subtitle: String {
        if let branch = git?.branch {
            return branch
        }
        return displayPath(path)
    }
}

struct StatusBadge: View {
    let group: GroupReport

    var body: some View {
        Label(group.statusText, systemImage: group.typeSymbol)
            .labelStyle(BadgeLabelStyle())
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(group.statusColor.opacity(0.14), in: Capsule())
            .foregroundStyle(group.statusColor)
            .fixedSize()
    }
}

private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .imageScale(.small)
            configuration.title
        }
    }
}

/// Five steps of cleanup value, on frees-alone bytes weighted by how likely the item can go.
struct CleanupMeter: View {
    static let steps = 5

    /// Frees-alone bytes weighted by how likely the item can go: `CleanupScore.weightedBytes`.
    let weightedBytes: Int64

    var level: Int {
        let gigabytes = Double(weightedBytes) / 1_000_000_000
        switch gigabytes {
        case 5...: return 5
        case 2..<5: return 4
        case 0.5..<2: return 3
        case 0.1..<0.5: return 2
        case let value where value > 0: return 1
        default: return 0
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.steps, id: \.self) { step in
                Capsule()
                    .fill(step < level ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 7, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Cleanup value \(level) of \(Self.steps)")
    }
}

/// Meter plus the facts behind it, for the table and the detail panel.
struct CleanupCell: View {
    let score: CleanupScore
    /// Meter and reason on one line, for the detail panel.
    var isInline = false

    var body: some View {
        let layout = isInline ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
        layout {
            CleanupMeter(weightedBytes: score.weightedBytes)
            Text(score.reason)
                .font(isInline ? .callout : .caption)
                .foregroundStyle(score.hasLocalWork ? AnyShapeStyle(GroupReport.localWorkColor) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .help("Frees \(bytes(score.weightedBytes)) weighted by how likely it can go (\(Int((score.confidence * 100).rounded()))%): \(score.reason)")
    }
}

extension Color {
    /// A color that differs between light and dark appearance.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}
