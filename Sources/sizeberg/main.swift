import SizeBergCore
import Foundation

let usage = """
Usage: sizeberg [--root PATH]... [--full] [--json | --plan]
       sizeberg --clear-cache

Shows what deleting worktrees, dependencies, build output and caches really frees on APFS,
where copy-on-write clones make du and Finder count shared data many times.

  --root PATH   Folder whose subfolders are scanned. Repeatable. Without it, the scan finds the folders
                that hold git repositories in your home folder, like ~/workspace or ~/Documents/GitHub.
  --full        Walk everything. By default only folders FSEvents reports as changed are walked again.
  --json        Print the full report as JSON.
  --plan        Print cleanup commands for stale worktrees and the package stores. Runs nothing.
  --clear-cache Delete the last report and the scan cache, so the next scan starts from nothing.

The last report is saved to ~/Library/Application Support/SizeBerg/last-scan.json for the app.
"""

var roots: [String] = []
var printJSON = false
var printPlan = false
var fullScan = false
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--json":
        printJSON = true
    case "--plan":
        printPlan = true
    case "--full":
        fullScan = true
    case "--clear-cache":
        do {
            try Report.clearCaches()
            print("Cleared ~/Library/Application Support/SizeBerg")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Could not clear the cache: \(error)\n".utf8))
            exit(1)
        }
    case "--root":
        guard let value = arguments.popFirst() else {
            FileHandle.standardError.write(Data("--root needs a path\n".utf8))
            exit(2)
        }
        roots.append((value as NSString).expandingTildeInPath)
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("Unknown argument: \(argument)\n\n\(usage)\n".utf8))
        exit(2)
    }
}

let showProgress = isatty(STDERR_FILENO) == 1
/// Debug aid: one line per update with elapsed time and totals, to measure how fast numbers settle.
let logsProgress = ProcessInfo.processInfo.environment["SIZEBERG_PROGRESS_LOG"] != nil
let scanner = Scanner(roots: roots.isEmpty ? nil : roots, fullScan: fullScan) { progress in
    let confirmed = progress.knownFreeableBytes
    if logsProgress {
        let elapsed = Date().timeIntervalSince(progress.startedAt)
        let line = String(
            format: "progress t=%.1f phase=%@ files=%d folders=%d/%d confirmed=%lld\n",
            elapsed, progress.phase.rawValue, progress.filesRead, progress.foldersDone, progress.foldersTotal, confirmed
        )
        FileHandle.standardError.write(Data(line.utf8))
        return
    }
    guard showProgress else { return }
    var line = "\r\(progress.phase.rawValue)"
    if progress.phase == .reading {
        line += ": \(progress.filesRead.formatted()) files"
        if let fraction = progress.fractionRead {
            line += " (\(Int(fraction * 100))%)"
        }
        line += ", \(progress.foldersDone.formatted()) of \(progress.foldersTotal.formatted()) folders"
        line += ", frees at least \(ByteFormat.string(confirmed)) so far"
    }
    FileHandle.standardError.write(Data((line + "\u{1B}[K").utf8))
}
let report = scanner.run()
if showProgress {
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
}
do {
    try report.saveToCache()
} catch {
    FileHandle.standardError.write(Data("Could not save the report: \(error)\n".utf8))
}

if printJSON {
    FileHandle.standardOutput.write(try report.jsonData())
    print()
} else if printPlan {
    print(report.cleanupPlan(selection: report.staleSelection))
} else {
    print(TextReport(report: report).render())
}
