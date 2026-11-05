import Foundation

struct WorktreeEntry {
    var path: String
    var branch: String?
    var isPrunable: Bool
}

struct GitSeed {
    var repoPath: String
    var worktreePath: String
    var branch: String?
    var isMainCheckout: Bool
}

/// Reads git state that tells a stale worktree from one in use.
final class GitInspector: @unchecked Sendable {
    /// A worktree whose work is merged or whose remote branch is gone counts as stale after this many quiet days.
    static let finishedWorkQuietDays = 3.0
    /// Any worktree counts as stale after this many quiet days.
    static let anyWorkQuietDays = 21.0

    private struct RepoContext {
        var defaultRef: String?
        var goneBranches: Set<String>
    }

    private let git: String
    private let contexts = Locked([String: RepoContext]())

    init?() {
        guard let git = Shell.find("git") else { return nil }
        self.git = git
    }

    func worktrees(from directory: String) -> [WorktreeEntry] {
        let result = Shell.run(git, ["-C", directory, "worktree", "list", "--porcelain"])
        guard result.status == 0 else { return [] }
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)), branch: nil, isPrunable: false)
            } else if line.hasPrefix("branch refs/heads/") {
                current?.branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("prunable") {
                current?.isPrunable = true
            } else if line == "bare" {
                current = nil
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    /// `unchanged` is the last scan's answer for this worktree when FSEvents saw no change in it since.
    func inspect(_ seed: GitSeed, unchanged: GitInfo? = nil) -> GitInfo {
        var info = GitInfo(
            repoPath: seed.repoPath,
            branch: seed.branch,
            headDate: nil,
            lastActive: lastActive(worktree: seed.worktreePath),
            upstreamGone: false,
            mergedIntoDefault: nil,
            hasUncommittedChanges: nil,
            hasUnpushedCommits: nil,
            status: .active
        )
        guard FileManager.default.fileExists(atPath: seed.worktreePath) else {
            info.status = .missing
            return info
        }
        guard !seed.isMainCheckout else { return info }

        let context = context(for: seed.repoPath)
        let path = seed.worktreePath
        if let branch = seed.branch {
            info.upstreamGone = context.goneBranches.contains(branch)
        }
        if info.lastActive == nil {
            let headTime = Shell.run(git, ["-C", path, "log", "-1", "--format=%ct"])
            if let seconds = TimeInterval(headTime.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                info.headDate = Date(timeIntervalSince1970: seconds)
                info.lastActive = info.headDate
            }
        }
        // Nothing used in the last few days counts as stale, so the slow checks only run for quiet worktrees.
        guard Self.quietDays(info) >= Self.finishedWorkQuietDays else { return info }

        var merged = false
        if let defaultRef = context.defaultRef {
            merged = Shell.run(git, ["-C", path, "merge-base", "--is-ancestor", "HEAD", defaultRef]).status == 0
        }
        info.mergedIntoDefault = merged
        info.hasUnpushedCommits = Self.hasUnpushedCommits(at: path, git: git)
        guard Self.isStale(info) else { return info }

        // git status reads the whole tree, so it only runs where it decides stale vs local work, and only
        // when something changed: no file change and the same HEAD means the same answer as last time.
        let head = Shell.run(git, ["-C", path, "rev-parse", "HEAD"], timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        info.headCommit = head.isEmpty ? nil : head
        if let unchanged, let known = unchanged.hasUncommittedChanges, unchanged.headCommit == info.headCommit, info.headCommit != nil {
            info.hasUncommittedChanges = known
        } else {
            info.hasUncommittedChanges = Self.hasUncommittedChanges(at: path, git: git)
        }
        info.status = info.hasLocalWork ? .staleWithLocalWork : .stale
        return info
    }

    /// A status that fails or times out counts as dirty: never suggest removing work we could not check.
    static func hasUncommittedChanges(at path: String, git: String) -> Bool {
        let status = Shell.run(git, ["-C", path, "status", "--porcelain"], timeout: 60)
        return status.status != 0 || status.timedOut || !status.output.isEmpty
    }

    /// Commits on HEAD that no remote branch has. A failed check counts as yes.
    static func hasUnpushedCommits(at path: String, git: String) -> Bool {
        let unpushed = Shell.run(git, ["-C", path, "rev-list", "-n", "1", "HEAD", "--not", "--remotes"])
        return unpushed.status != 0 || !unpushed.output.isEmpty
    }

    private static func quietDays(_ info: GitInfo) -> Double {
        info.lastActive.map { -$0.timeIntervalSinceNow / 86_400 } ?? .infinity
    }

    private static func isStale(_ info: GitInfo) -> Bool {
        let quietDays = quietDays(info)
        return (info.workIsFinished && quietDays >= finishedWorkQuietDays) || quietDays >= anyWorkQuietDays
    }

    /// The index file changes on every checkout, commit, add and status, so its mtime tracks use.
    private func lastActive(worktree: String) -> Date? {
        let dotGit = worktree + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return modificationDate(of: dotGit + "/index")
        }
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
              pointer.hasPrefix("gitdir: ") else { return nil }
        var gitDirectory = pointer.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !gitDirectory.hasPrefix("/") {
            gitDirectory = worktree + "/" + gitDirectory
        }
        return modificationDate(of: gitDirectory + "/index")
    }

    private func context(for repo: String) -> RepoContext {
        if let cached = contexts.withLock({ $0[repo] }) {
            return cached
        }
        let context = RepoContext(defaultRef: defaultRef(of: repo), goneBranches: goneBranches(of: repo))
        contexts.withLock { $0[repo] = context }
        return context
    }

    private func defaultRef(of repo: String) -> String? {
        let symbolic = Shell.run(git, ["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        let name = symbolic.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if symbolic.status == 0, !name.isEmpty {
            return name
        }
        for candidate in ["origin/master", "origin/main", "master", "main"] {
            if Shell.run(git, ["-C", repo, "rev-parse", "--verify", "--quiet", candidate]).status == 0 {
                return candidate
            }
        }
        return nil
    }

    private func goneBranches(of repo: String) -> Set<String> {
        let result = Shell.run(git, ["-C", repo, "for-each-ref", "--format=%(refname:short)\t%(upstream:track)", "refs/heads"])
        var gone = Set<String>()
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, parts[1].contains("gone") {
                gone.insert(String(parts[0]))
            }
        }
        return gone
    }
}
