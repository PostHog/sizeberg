import Foundation

/// One cleanup command, and the selected items it cleans: several items can share one command,
/// such as missing worktrees of one repository that a single prune removes.
public struct CleanupStep: Identifiable, Sendable {
    public var groupIDs: [Int]
    public var name: String
    public var kind: GroupKind
    public var path: String
    public var command: String
    public var expectedBytes: Int64
    /// Set when the step deletes only build output and caches inside an item that stays.
    public var isTrim = false
    public var folders: [String] = []

    public var id: String { "\(groupIDs[0])-\(isTrim ? "trim" : "item")" }
}

public enum CleanupOutcome: Sendable, Equatable {
    case done
    /// Ran, but left part of it in place, with the reason.
    case partlyDone(String)
    /// Not run, because running it now could lose work.
    case skipped(String)
    case failed(String)

    public var ran: Bool {
        switch self {
        case .done, .partlyDone: return true
        case .skipped, .failed: return false
        }
    }
}

/// Runs the commands of a cleanup plan. Each command runs exactly as copied, in an interactive
/// login shell: zsh reads .zshrc only for interactive shells, and that is where pnpm, fnm or nvm
/// usually put their PATH lines, so tools are found the way Terminal finds them.
public enum CleanupRunner {
    /// Items whose command the app can run, in plan order, and the rest with the reason.
    /// Worktrees go first so a store prune afterwards can drop their packages.
    /// The build output item becomes one step per item that holds build output, after the deleted
    /// items. An item that is deleted is not trimmed too.
    public static func plan(for report: Report, selection: Set<Int>) -> (steps: [CleanupStep], manual: [GroupReport]) {
        let trimming = selection.contains(Report.buildOutputID) ? report.trimmableIDs : []
        let order: [GroupKind] = [.worktree, .project, .cache]
        var steps: [CleanupStep] = []
        var stepByCommand: [String: Int] = [:]
        let selected = report.groups.filter { selection.contains($0.id) }
        let manual = selected.filter { !order.contains($0.kind) || $0.cleanupCommand == nil }
        for kind in order {
            if kind == .cache {
                steps += trimSteps(report: report, trimming: trimming.subtracting(selection))
            }
            for group in selected where group.kind == kind {
                guard let command = group.cleanupCommand else { continue }
                if let index = stepByCommand[command] {
                    steps[index].groupIDs.append(group.id)
                    steps[index].expectedBytes += group.freeableAloneBytes
                    continue
                }
                stepByCommand[command] = steps.count
                steps.append(CleanupStep(
                    groupIDs: [group.id], name: group.name, kind: group.kind, path: group.path,
                    command: command, expectedBytes: group.freeableAloneBytes
                ))
            }
        }
        return (steps, manual)
    }

    /// One step per item, for its build output and caches together, biggest first.
    private static func trimSteps(report: Report, trimming: Set<Int>) -> [CleanupStep] {
        report.groups.filter { trimming.contains($0.id) && $0.trimBytes > 0 }
            .sorted { $0.trimBytes > $1.trimBytes }
            .map { group in
            let folders = group.trimmableBuckets.flatMap { $0.folders ?? [] }
            return CleanupStep(
                groupIDs: [group.id], name: group.name, kind: group.kind, path: group.path,
                command: trimCommand(folders), expectedBytes: group.trimBytes, isTrim: true, folders: folders
            )
        }
    }

    public static func trimCommand(_ folders: [String]) -> String {
        "rm -rf " + folders.map(shellQuote).joined(separator: " ")
    }

    /// Why an item the plan cannot run is left out.
    public static func reasonNotIncluded(_ group: GroupReport) -> String {
        group.kind == .system ? "Container disks: run the command in Terminal." : "No cleanup command."
    }

    /// Checks an item again right before deleting it: the scan may be minutes old. Nil means safe to run.
    static func reasonToSkip(_ step: CleanupStep) -> String? {
        guard FileManager.default.fileExists(atPath: step.path) else { return nil }
        switch step.kind {
        case .worktree:
            return worktreeReasonToSkip(step)
        case .project:
            return folderReasonToSkip(step)
        default:
            return nil
        }
    }

    /// A folder is removed with rm -rf, so anything written into it since the scan keeps it.
    private static func folderReasonToSkip(_ step: CleanupStep) -> String? {
        if FileManager.default.fileExists(atPath: step.path + "/.git") {
            return "Is a git repository now."
        }
        guard let eventID = ScanCache().loadState()?.eventID,
              let changes = ChangeLog.changes(since: eventID, under: [step.path]) else {
            return "Could not check for changes since the scan."
        }
        return changes.isEmpty ? nil : "Changed since the scan."
    }

    /// git itself refuses uncommitted changes; commits no remote has are checked here.
    private static func worktreeReasonToSkip(_ step: CleanupStep) -> String? {
        guard let git = Shell.find("git") else { return "git not found." }
        if GitInspector.hasUncommittedChanges(at: step.path, git: git) {
            return "Has uncommitted changes now."
        }
        // Stricter than the scan's local-work rule: merged work no remote has is kept too.
        if GitInspector.hasUnpushedCommits(at: step.path, git: git) {
            return "Has commits that no remote has."
        }
        return nil
    }

    /// Folders that still exist and hold no file git tracks. A committed dist folder or a
    /// .flox/env stays, because deleting it would change the checkout itself.
    static func foldersSafeToTrim(_ step: CleanupStep) -> [String] {
        let existing = step.folders.filter { FileManager.default.fileExists(atPath: $0) }
        guard step.kind == .worktree || step.kind == .mainCheckout, !existing.isEmpty else { return existing }
        guard let git = Shell.find("git") else { return [] }
        let result = Shell.run(git, ["-C", step.path, "ls-files", "--full-name", "-z", "--"] + existing, timeout: 60)
        // Without an answer from git, nothing counts as safe.
        guard result.status == 0, !result.timedOut else { return [] }
        let root = Shell.run(git, ["-C", step.path, "rev-parse", "--show-toplevel"], timeout: 10)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return [] }
        let tracked = result.output.split(separator: "\0").map { realPath(root + "/" + $0) }
        return existing.filter { folder in
            let prefix = realPath(folder) + "/"
            return !tracked.contains { $0.hasPrefix(prefix) }
        }
    }

    private static func runTrim(_ step: CleanupStep) -> CleanupOutcome {
        let folders = foldersSafeToTrim(step)
        guard !folders.isEmpty else {
            return .skipped("The folders are gone, hold files git tracks, or git did not answer.")
        }
        var trimmed = step
        trimmed.command = trimCommand(folders)
        let outcome = runCommand(trimmed)
        let kept = step.folders.count - folders.count
        guard outcome == .done, kept > 0 else { return outcome }
        return .partlyDone("Kept \(kept) of \(step.folders.count) folders: they are gone or hold files git tracks.")
    }

    public static func run(_ step: CleanupStep) -> CleanupOutcome {
        if step.isTrim {
            return runTrim(step)
        }
        if let reason = reasonToSkip(step) {
            return .skipped(reason)
        }
        return runCommand(step)
    }

    private static func runCommand(_ step: CleanupStep) -> CleanupOutcome {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let result = Shell.run(shell, ["-i", "-l", "-c", step.command], timeout: 30 * 60, mergeErrors: true)
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
        Scanner.volume(NSHomeDirectory()).freeBytes
    }
}
