import Foundation

/// One cleanup command for one selected item, as the plan shows it.
public struct CleanupStep: Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var kind: GroupKind
    public var path: String
    public var command: String
    public var expectedBytes: Int64
}

public enum CleanupOutcome: Sendable, Equatable {
    case done
    /// Not run, because running it now could lose work.
    case skipped(String)
    case failed(String)
}

/// Runs the commands of a cleanup plan. Each command runs exactly as copied, in a login shell,
/// so tools like pnpm and uv are found the way Terminal finds them.
public enum CleanupRunner {
    /// Items whose command the app can run, in plan order, and the rest with the reason.
    /// Worktrees go first so a store prune afterwards can drop their packages.
    public static func plan(for report: Report, selection: Set<Int>) -> (steps: [CleanupStep], manual: [(name: String, reason: String)]) {
        let order: [GroupKind] = [.worktree, .project, .cache]
        var steps: [CleanupStep] = []
        var manual: [(name: String, reason: String)] = []
        var seenCommands = Set<String>()
        let selected = report.groups.filter { selection.contains($0.id) }
        for group in selected where !order.contains(group.kind) {
            manual.append((group.name, group.kind == .system ? "Container disks: run the command in Terminal." : "No cleanup command."))
        }
        for kind in order {
            for group in selected where group.kind == kind {
                guard let command = group.cleanupCommand else {
                    manual.append((group.name, "No cleanup command."))
                    continue
                }
                // Several items can share one command, such as a store prune.
                guard seenCommands.insert(command).inserted else { continue }
                steps.append(CleanupStep(
                    id: group.id, name: group.name, kind: group.kind, path: group.path,
                    command: command, expectedBytes: group.freeableAloneBytes
                ))
            }
        }
        return (steps, manual)
    }

    /// Checks a worktree again right before deleting it: the scan may be minutes old.
    /// Nil means safe to run. git itself refuses uncommitted changes; commits no remote has are checked here.
    static func reasonToSkip(_ step: CleanupStep) -> String? {
        guard step.kind == .worktree, FileManager.default.fileExists(atPath: step.path) else { return nil }
        guard let git = Shell.find("git") else { return "git not found." }
        let status = Shell.run(git, ["-C", step.path, "status", "--porcelain"], timeout: 60)
        if status.status != 0 || status.timedOut {
            return "Could not check for uncommitted changes."
        }
        if !status.output.isEmpty {
            return "Has uncommitted changes now."
        }
        let unpushed = Shell.run(git, ["-C", step.path, "rev-list", "-n", "1", "HEAD", "--not", "--remotes"])
        if unpushed.status != 0 || !unpushed.output.isEmpty {
            return "Has commits that no remote has."
        }
        return nil
    }

    public static func run(_ step: CleanupStep) -> CleanupOutcome {
        if let reason = reasonToSkip(step) {
            return .skipped(reason)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let result = Shell.run(shell, ["-l", "-c", step.command], timeout: 30 * 60, mergeErrors: true)
        if result.timedOut {
            return .failed("Stopped after 30 minutes.")
        }
        guard result.status == 0 else {
            let lastLines = result.output.split(separator: "\n").suffix(3).joined(separator: "\n")
            return .failed(lastLines.isEmpty ? "Exited with status \(result.status)." : lastLines)
        }
        return .done
    }

    /// Free bytes on the volume that holds the home folder, for before and after.
    public static func freeBytes() -> Int64 {
        var info = statfs()
        guard statfs(NSHomeDirectory(), &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}
