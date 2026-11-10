import Foundation
@testable import SizeBergCore
import Testing

/// Deleting a temp folder a running tool still writes to breaks that run, and a folder name that only
/// looks generated can be someone's own work. Only folders with a generated name, unchanged for a while
/// and not used by any process, may be offered.
struct TempLeftoversTests {
    @Test(arguments: [
        ("tmpk3x_9a1b", "tmp"),
        ("lint-3d_ab12cd34", "lint-3d_"),
        ("tmp.Ab12Cd34Ef", "tmp."),
        ("mypy-console-decentral", nil),
        ("lint-target-arch-gates", nil),
        ("com.apple.launchd.AbC123xyz", nil),
        ("com.google.Chrome.chrome_url_fetcher_.Ab12Cd", nil),
        ("TemporaryDirectory.Ab12Cd", nil),
        ("node-compile-cache", nil),
        ("report.backup", nil),
        ("backup-20251110", nil),
    ] as [(String, String?)])
    func generatedPrefix(name: String, prefix: String?) {
        #expect(TempLeftovers.generatedPrefix(name) == prefix)
    }

    @Test func groupsQuietGeneratedFoldersAndKeepsTheRest() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sizeberg-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let temp = base + "/tmp", cache = base + "/cache"
        let folders = [
            "\(temp)/tmpaa11bb22", "\(temp)/tmpcc33dd44", "\(temp)/tmpyoung_01", "\(temp)/tmpused_001",
            "\(temp)/notes", "\(temp)/target-run/debug",
            "\(cache)/lint-target-n1/debug", "\(cache)/uv", "\(cache)/plain",
        ]
        for folder in folders {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        for tagged in ["\(temp)/target-run", "\(cache)/lint-target-n1", "\(cache)/uv"] {
            FileManager.default.createFile(atPath: tagged + "/CACHEDIR.TAG", contents: Data())
        }
        let later = Date().addingTimeInterval(TempLeftovers.quietTime + 60)
        FileManager.default.createFile(atPath: "\(temp)/tmpyoung_01/facts.jsonl", contents: Data())
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(temp)/tmpyoung_01/facts.jsonl")
        let process = AgentActivity.ProcessFolder(pid: 7, executable: "/usr/bin/cargo", folder: realPath(temp) + "/tmpused_001/out.json")

        let found = TempLeftovers(tempRoots: [temp], cacheRoot: cache, now: later)
            .find(claimed: [realPath("\(cache)/uv")], inUse: [process])

        let realTemp = realPath(temp), realCache = realPath(cache)
        #expect(found.leftovers == [.init(prefix: "tmp", paths: ["\(realTemp)/tmpaa11bb22", "\(realTemp)/tmpcc33dd44"])])
        #expect(found.toolCaches.map(\.path) == ["\(realTemp)/target-run", "\(realCache)/lint-target-n1"])
        #expect(found.other[realTemp] == ["\(realTemp)/notes", "\(realTemp)/tmpused_001", "\(realTemp)/tmpyoung_01"])
        #expect(TempLeftovers(tempRoots: [temp], cacheRoot: cache, now: later).reasonToSkip(found.leftovers[0].paths) == nil)
        // A rewrite deep inside changes neither the folder nor anything directly in it.
        try FileManager.default.createDirectory(atPath: "\(realTemp)/tmpcc33dd44/out", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(realTemp)/tmpcc33dd44/out/result.json", contents: Data())
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: "\(realTemp)/tmpcc33dd44/out")
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: "\(realTemp)/tmpcc33dd44/out/result.json")
        #expect(TempLeftovers(tempRoots: [temp], cacheRoot: cache, now: later).reasonToSkip(found.leftovers[0].paths) == "tmpcc33dd44 changed since the scan.")
        try FileManager.default.removeItem(atPath: "\(realTemp)/tmpcc33dd44")
        try FileManager.default.createDirectory(atPath: "\(realTemp)/tmpaa11bb22/clone/.git", withIntermediateDirectories: true)
        #expect(TempLeftovers(tempRoots: [temp], cacheRoot: cache, now: later).reasonToSkip(found.leftovers[0].paths) == "tmpaa11bb22 holds a git repository now.")
        #expect(found.other[realCache] == nil)
    }

    /// TMPDIR=/tmp would scan every folder twice: two items with the same folders, and bytes counted twice.
    @Test func aRootInsideAnotherIsScannedOnce() {
        let roots = TempLeftovers(tempRoots: ["/private/tmp", "/tmp", "/private/tmp/claude-1/session"], cacheRoot: "/nonexistent").tempRoots
        #expect(roots == ["/private/tmp"])
    }

    /// The step's own path is its first folder. When that one is gone, the other folders still need their checks.
    @Test func groupedDeleteChecksTheRestWhenTheFirstFolderIsGone() throws {
        let temp = realPath(NSTemporaryDirectory())
        let gone = temp + "/tmpgone_\(Int.random(in: 100...999))", fresh = temp + "/tmpnew_\(Int.random(in: 1000...9999))"
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fresh) }
        let step = CleanupStep(groupIDs: [0], name: "tmp*", kind: .cache, path: gone, command: "rm -rf",
                               expectedBytes: 0, folders: [gone, fresh], section: .tempLeftovers)

        #expect(CleanupRunner.reasonToSkip(step) != nil)
    }
}
