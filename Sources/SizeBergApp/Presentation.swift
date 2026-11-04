import SizeBergCore
import SwiftUI

func bytes(_ value: Int64) -> String {
    ByteFormat.string(value)
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

extension GroupReport {
    var statusText: String {
        switch kind {
        case .mainCheckout: return "Main checkout"
        case .project: return "Folder"
        case .cache: return "Cache"
        case .system: return "Containers"
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
        case .staleWithLocalWork: return .orange
        case .missing: return .secondary
        default: break
        }
        switch kind {
        case .worktree, .mainCheckout: return .blue
        case .cache: return Color(red: 0.86, green: 0.72, blue: 0.22)
        case .system: return .indigo
        case .project: return .gray
        }
    }

    var statusSortKey: String { statusText }

    var subtitle: String {
        if let branch = git?.branch {
            return branch
        }
        return displayPath(path)
    }

    var lastActiveSortKey: Date {
        git?.lastActive ?? .distantPast
    }

    var lastActiveText: String {
        guard let date = git?.lastActive else { return "" }
        return date.formatted(.relative(presentation: .named))
    }

    /// Container disks are listed for context; the scan does not split them into removable parts.
    var freesAloneText: String {
        kind == .system ? "n/a" : bytes(freeableAloneBytes)
    }
}

struct StatusBadge: View {
    let group: GroupReport

    var body: some View {
        Text(group.statusText)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(group.statusColor.opacity(0.18), in: Capsule())
            .foregroundStyle(group.statusColor)
    }
}
