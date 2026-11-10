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

/// What deleting build output leaves in place, like "Leaves 3k+ folders under 1 MB (430 MB) and 3 that git tracks".
func leftOutText(smallCount: Int, smallBytes: Int64, trackedCount: Int) -> String? {
    var parts: [String] = []
    if smallCount > 0 {
        parts.append("\(roughCount(smallCount)) \(smallCount == 1 ? "folder" : "folders") under \(bytes(BuildFolder.smallBytes)) (\(bytes(smallBytes)))")
    }
    if trackedCount > 0 {
        parts.append("\(trackedCount) that git tracks")
    }
    return parts.isEmpty ? nil : "Leaves " + parts.joined(separator: " and ")
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
        if let section {
            if isSectionItem { return "Agent waste" }
            if inUse == true { return "In use" }
            if section == .other { return "Size only" }
            return selectable ? "Leftover" : "Kept"
        }
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
        if section != nil, !isSectionItem, inUse == true || !selectable {
            return .secondary
        }
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
        if section != nil, paths.count > 1 {
            return "\(paths.count) folders in \(displayPath((path as NSString).deletingLastPathComponent))"
        }
        return displayPath(path)
    }
}

/// What git says about a worktree's branch, in the colors GitHub uses. A branch can show two:
/// local work, which keeps the worktree, and how its work ended, merged or with the remote branch deleted.
enum BranchState {
    case localWork(String)
    case merged
    case remoteGone

    static func states(of git: GitInfo?) -> [BranchState] {
        guard let git else { return [] }
        var states: [BranchState] = []
        if git.hasUncommittedChanges == true {
            states.append(.localWork("Uncommitted changes"))
        } else if git.hasUnpushedCommits == true, git.mergedIntoDefault != true {
            states.append(.localWork("Commits that no remote has"))
        }
        if git.mergedIntoDefault == true {
            states.append(.merged)
        } else if git.upstreamGone {
            states.append(.remoteGone)
        }
        return states
    }

    var symbol: String {
        switch self {
        case .localWork: return "pencil.circle.fill"
        case .merged: return "arrow.triangle.merge"
        case .remoteGone: return "icloud.slash"
        }
    }

    var color: Color {
        switch self {
        case .localWork: return GroupReport.localWorkColor
        case .merged: return .adaptive(light: Color(red: 0.51, green: 0.31, blue: 0.87), dark: Color(red: 0.67, green: 0.51, blue: 1.0))
        case .remoteGone: return .secondary
        }
    }

    var help: String {
        switch self {
        case .localWork(let what): return what
        case .merged: return "Merged into the default branch"
        case .remoteGone: return "The remote branch is deleted"
        }
    }
}

/// A coding agent in a checkout, for the Agent column: working now, or how long ago it last worked.
/// Older than a few days says nothing; the inspector still shows when.
struct AgentCell: View {
    static let recentDays: Double = 3
    static let workingColor = Color.adaptive(light: Color(red: 0.0, green: 0.55, blue: 0.45), dark: .mint)

    let agent: AgentState?

    var body: some View {
        if let agent, let label = Self.label(agent) {
            Label(label, systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(agent.isWorking ? .semibold : .regular))
                .foregroundStyle(agent.isWorking ? AnyShapeStyle(Self.workingColor) : AnyShapeStyle(.secondary))
                .help(agent.isWorking ? "A coding agent is working here" : "A coding agent last worked here \(label)")
        }
    }

    static func label(_ agent: AgentState) -> String? {
        if agent.isWorking {
            return "Working"
        }
        guard let last = agent.lastActive else { return nil }
        let minutes = Int(Date().timeIntervalSince(last) / 60)
        switch minutes {
        case ..<60: return "\(max(minutes, 1)) min ago"
        case ..<(24 * 60): return "\(minutes / 60) h ago"
        case ..<(Int(recentDays) * 24 * 60): return "\(minutes / (24 * 60)) d ago"
        default: return nil
        }
    }
}

/// A worktree's branch with its git state in front, like a merged branch with a purple merge icon.
struct BranchLabel: View {
    let group: GroupReport

    var body: some View {
        HStack(spacing: 4) {
            if group.kind == .worktree {
                ForEach(Array(BranchState.states(of: group.git).enumerated()), id: \.offset) { _, state in
                    Image(systemName: state.symbol)
                        .foregroundStyle(state.color)
                        .imageScale(.medium)
                        .help(state.help)
                        .accessibilityLabel(state.help)
                }
            }
            Text(group.subtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
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

extension CleanupVerdict {
    var title: String {
        switch self {
        case .safe: return "Safe"
        case .likely: return "Likely"
        case .recent: return "Recent"
        case .inUse: return "In use"
        case .risky: return "Risky"
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .likely: return "circle.lefthalf.filled"
        case .recent: return "clock"
        case .inUse: return "bolt.circle"
        case .risky: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .adaptive(light: Color(red: 0.13, green: 0.50, blue: 0.24), dark: Color(red: 0.40, green: 0.82, blue: 0.50))
        case .likely: return .blue
        case .recent, .inUse: return .secondary
        case .risky: return GroupReport.localWorkColor
        }
    }

    /// What the word means, for the tooltip.
    var explanation: String {
        switch self {
        case .safe: return "Deleting it loses nothing: the next install, build or run puts it back, or nothing uses it."
        case .likely: return "Quiet, without local work. Most likely no longer needed."
        case .recent: return "Used lately. Nothing would be lost, but you may still need it."
        case .inUse: return "An agent or a process works here now."
        case .risky: return "Deleting it loses uncommitted changes or commits no remote has."
        }
    }
}

/// The verdict as a word with a symbol. Size has its own column, so the badge says only what deleting loses.
struct VerdictBadge: View {
    let verdict: CleanupVerdict

    var body: some View {
        Label(verdict.title, systemImage: verdict.symbol)
            .labelStyle(BadgeLabelStyle())
            .font(.callout.weight(.medium))
            .foregroundStyle(verdict.color)
    }
}

/// Verdict plus the facts behind it, for the table and the detail panel.
struct CleanupCell: View {
    let score: CleanupScore
    /// Verdict and reason on one line, for the detail panel.
    var isInline = false

    var body: some View {
        let layout = isInline ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 1))
        layout {
            VerdictBadge(verdict: score.verdict)
            if !score.reason.isEmpty {
                Text(score.reason)
                    .font(isInline ? .callout : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help("\(score.verdict.explanation) The list sorts by what it frees times how sure the scan is (\(Int((score.confidence * 100).rounded()))% here).")
        .accessibilityElement(children: .combine)
    }
}

/// A checkout's worktrees or a section's items: the riskiest verdict, and how many share it.
struct CleanupSummaryCell: View {
    let scores: [CleanupScore]

    var body: some View {
        if let worst = scores.map(\.verdict).max() {
            let count = scores.filter { $0.verdict == worst }.count
            VStack(alignment: .leading, spacing: 1) {
                VerdictBadge(verdict: worst)
                Text(summary(worst: worst, count: count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("The riskiest of its items. \(worst.explanation)")
            .accessibilityElement(children: .combine)
        }
    }

    private func summary(worst: CleanupVerdict, count: Int) -> String {
        if count == scores.count {
            return count == 1 ? "its only item" : "all \(count)"
        }
        let safe = scores.filter { $0.verdict == .safe }.count
        return "\(count) of \(scores.count)" + (safe > 0 && worst != .safe ? " · \(safe) safe" : "")
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

extension View {
    /// Liquid Glass on macOS 26 and later, the classic filled button on macOS 15.
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
