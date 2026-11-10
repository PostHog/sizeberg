import Foundation

/// What deleting an item would lose, in one word. The table shows it; size has a column of its own.
/// It follows what is lost, not the confidence number: a cache scores 0.6 because rebuilding it takes
/// time, yet deleting it loses nothing.
public enum CleanupVerdict: Int, Comparable, Sendable, CaseIterable {
    /// Nothing is lost: caches, build output, leftovers of finished runs, a worktree whose folder is gone.
    case safe
    /// Quiet and without local work, so most likely not needed.
    case likely
    /// Used lately, though nothing would be lost.
    case recent
    /// An agent or a process works there now.
    case inUse
    /// Deleting would lose uncommitted changes or commits no remote has.
    case risky

    public static func < (lhs: CleanupVerdict, rhs: CleanupVerdict) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

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
    public var verdict: CleanupVerdict
}

extension GroupReport {
    /// Caches fill again on the next install or build, which costs time but loses nothing.
    static let cacheConfidence = 0.6
    /// A scratch or temp folder of a run that ended is used by nothing; only a resumed session reads it again.
    static let leftoverConfidence = 0.9
    /// Quiet days at which confidence reaches about 63%. In line with the stale rules, which wait
    /// 3 days for merged or remote-gone work and 21 days for any work (95% here).
    static let quietDaysScale = 7.0
    static let finishedWorkQuietDaysScale = 3.0
    /// Local work can be lost, so it ranks far lower however quiet it is.
    static let localWorkFactor = 0.3
    /// The scan runs git status only for stale worktrees. Elsewhere uncommitted work is unknown, not absent.
    static let uncheckedFactor = 0.5
    /// Below this, an item without local work counts as used lately rather than likely not needed.
    static let likelyConfidence = 0.4
    /// A folder outside git has no merge state to go on.
    static let folderFactor = 0.5

    /// Nil for main checkouts, container disks and folders not offered for deletion: the scan never proposes deleting them.
    public func cleanupScore(now: Date = Date()) -> CleanupScore? {
        switch kind {
        case .mainCheckout, .system:
            return nil
        case .project where cleanupCommand == nil:
            return nil
        case .cache where section != nil:
            // Kept agent waste still gets a verdict, so a section's summary covers what stays too.
            guard cleanupCommand != nil else {
                if section == .other { return nil }
                if holdsGitData == true {
                    return score(confidence: 0, reason: "holds a git repository", verdict: .risky)
                }
                return inUse == true
                    ? score(confidence: 0, reason: "a process uses it", verdict: .inUse)
                    : score(confidence: 0, reason: "changed lately", verdict: .recent)
            }
            return section == .toolCaches
                ? score(confidence: Self.cacheConfidence, reason: "next run builds it again", verdict: .safe)
                : score(confidence: Self.leftoverConfidence, reason: "left by a finished run", verdict: .safe)
        case .cache:
            return score(confidence: Self.cacheConfidence, reason: "refills on next install or build", verdict: .safe)
        case .buildOutput:
            return score(confidence: Self.cacheConfidence, reason: "next build puts it back", verdict: .safe)
        case .worktree, .project:
            break
        }
        if agent?.isWorking == true {
            return score(confidence: 0, reason: "agent working", verdict: .inUse)
        }
        guard let git else {
            return score(confidence: Self.folderFactor * Self.cacheConfidence, reason: "not a git repository", verdict: .likely)
        }
        if git.status == .missing {
            return score(confidence: 1, reason: "folder gone, prune", verdict: .safe)
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
                parts.append("git status not checked")
            }
        }
        if kind == .project {
            confidence *= Self.folderFactor
        }
        let verdict: CleanupVerdict = hasLocalWork ? .risky : confidence >= Self.likelyConfidence ? .likely : .recent
        return score(confidence: confidence, reason: parts.joined(separator: " · "), verdict: verdict)
    }

    private func score(confidence: Double, reason: String, verdict: CleanupVerdict) -> CleanupScore {
        CleanupScore(
            weightedBytes: Int64(Double(freeableAloneBytes) * confidence),
            confidence: confidence,
            reason: reason,
            hasLocalWork: verdict == .risky,
            verdict: verdict
        )
    }

    /// Sort key for tables: items the scan never proposes deleting go last.
    public var cleanupSortKey: Int64 {
        cleanupScore()?.weightedBytes ?? -1
    }
}
