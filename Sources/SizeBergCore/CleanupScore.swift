import Foundation

/// How worthwhile deleting an item is: what it frees alone, weighted by how likely it is no longer needed.
/// Ranks a big quiet merged worktree above a bigger one in daily use.
public struct CleanupScore: Sendable {
    /// Frees-alone bytes times `confidence`. The sort key.
    public var weightedBytes: Int64
    /// 0 to 1: how sure the scan is that the item can go.
    public var confidence: Double
    /// Short facts behind the confidence, such as "quiet 9 days · merged".
    public var reason: String
    /// True when deleting would lose uncommitted changes or commits no remote has.
    public var hasLocalWork: Bool
}

extension GroupReport {
    /// Caches fill again on the next install or build, which costs time but loses nothing.
    static let cacheConfidence = 0.6
    /// Quiet days at which confidence reaches about 63%. In line with the stale rules, which wait
    /// 3 days for merged or remote-gone work and 21 days for any work (95% here).
    static let quietDaysScale = 7.0
    static let finishedWorkQuietDaysScale = 3.0
    /// Local work can be lost, so it ranks far lower however quiet it is.
    static let localWorkFactor = 0.3
    /// The scan runs git status only for stale worktrees. Elsewhere uncommitted work is unknown, not absent.
    static let uncheckedFactor = 0.5
    /// A folder outside git has no merge state to go on.
    static let folderFactor = 0.5

    /// Nil for main checkouts and container disks: the scan never proposes deleting them.
    public func cleanupScore(now: Date = Date()) -> CleanupScore? {
        switch kind {
        case .mainCheckout, .system:
            return nil
        case .cache:
            return score(confidence: Self.cacheConfidence, reason: "refills when used", hasLocalWork: false)
        case .buildOutput:
            return score(confidence: Self.cacheConfidence, reason: "next build puts it back", hasLocalWork: false)
        case .worktree, .project:
            break
        }
        guard let git else {
            return score(confidence: Self.folderFactor * Self.cacheConfidence, reason: "folder", hasLocalWork: false)
        }
        if git.status == .missing {
            return score(confidence: 1, reason: "folder gone, prune", hasLocalWork: false)
        }

        var parts: [String] = []
        let quietDays = git.lastActive.map { max(0, now.timeIntervalSince($0) / 86_400) }
        if let quietDays {
            parts.append(quietDays < 1 ? "used today" : "quiet \(Int(quietDays)) \(Int(quietDays) == 1 ? "day" : "days")")
        }
        if git.mergedIntoDefault == true {
            parts.append("merged")
        } else if git.upstreamGone {
            parts.append("remote gone")
        }
        // Finished work goes stale faster, but a worktree used today is still in use.
        let scale = git.workIsFinished ? Self.finishedWorkQuietDaysScale : Self.quietDaysScale
        var confidence = 1 - exp(-(quietDays ?? Self.quietDaysScale * 3) / scale)
        let hasLocalWork = git.hasLocalWork
        if hasLocalWork {
            parts.append("local work")
            confidence *= Self.localWorkFactor
        } else if git.hasUncommittedChanges == nil {
            confidence *= Self.uncheckedFactor
            // Only worth saying where it holds a quiet worktree back; in-use ones rank low anyway.
            if (quietDays ?? 0) >= 3 {
                parts.append("changes not checked")
            }
        }
        if kind == .project {
            confidence *= Self.folderFactor
        }
        return score(confidence: confidence, reason: parts.joined(separator: " · "), hasLocalWork: hasLocalWork)
    }

    private func score(confidence: Double, reason: String, hasLocalWork: Bool) -> CleanupScore {
        CleanupScore(
            weightedBytes: Int64(Double(freeableAloneBytes) * confidence),
            confidence: confidence,
            reason: reason,
            hasLocalWork: hasLocalWork
        )
    }

    /// Sort key for tables: items the scan never proposes deleting go last.
    public var cleanupSortKey: Int64 {
        cleanupScore()?.weightedBytes ?? -1
    }
}
