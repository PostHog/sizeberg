@testable import SizeBergCore
import Testing

/// A rescan reuses cached segments FSEvents reports as unchanged, so a missed change shows stale numbers.
struct ChangeMappingTests {
    private static let segments = [
        Segment(group: 0, path: "/w/repo", kind: .source, filesOnly: true, key: "root"),
        Segment(group: 0, path: "/w/repo/src", kind: .source, filesOnly: false, key: "src"),
        Segment(group: 0, path: "/w/repo/node_modules", kind: .dependencies, filesOnly: false, key: "deps"),
        Segment(group: 1, path: "/w/other", kind: .source, filesOnly: true, key: "other"),
    ]

    @Test(arguments: [
        // A change deep in a folder invalidates only that folder's segment.
        (path: "/w/repo/src/a/b", recursive: false, expected: Set([1])),
        // A change in the root's own files invalidates only the files-only segment.
        (path: "/w/repo", recursive: false, expected: Set([0])),
        // Coalesced changes below the root (MustScanSubDirs) invalidate every segment under it.
        (path: "/w/repo", recursive: true, expected: Set([0, 1, 2])),
    ])
    func changesInvalidateTheSegmentsThatHoldThem(path: String, recursive: Bool, expected: Set<Int>) {
        let changes = [ChangeLog.Change(path: path, includesSubdirectories: recursive)]
        #expect(Scanner.segmentsOwning(changes, segments: Self.segments) == expected)
    }

    /// With thousands of roots the FSEvents query fails, and every rescan walks everything (0.1.8 with
    /// thousands of temp folders). The watched roots must stay few and still cover every folder.
    @Test func manySiblingFoldersAreWatchedThroughTheirParent() {
        let temp = (0..<4_000).map { "/private/var/folders/T/tmp\($0)" }
        let paths = temp + ["/Users/me/code/app", "/Users/me/code/api", "/Users/me/.cache/uv"]

        let roots = ChangeLog.watchRoots(paths)

        #expect(roots.count <= ChangeLog.maxRoots)
        #expect(roots.contains("/private/var/folders/T"))
        #expect(roots.contains("/Users/me/code/app"))
        #expect(paths.allSatisfy { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } })
    }

    /// One scratch session per project: no two roots share a parent, and the limit must still hold.
    @Test func foldersWithoutSiblingsStillStayUnderTheLimit() {
        let paths = (0..<4_000).map { "/private/tmp/claude-501/-project\($0)/session" }

        let roots = ChangeLog.watchRoots(paths)

        #expect(roots.count <= ChangeLog.maxRoots)
        #expect(paths.allSatisfy { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } })
    }
}
