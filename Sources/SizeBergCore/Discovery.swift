import Foundation

struct GroupSpec {
    var kind: GroupKind
    var name: String
    var paths: [String]
    var classify: Bool
    var defaultKind: BucketKind
    var gitSeed: GitSeed?
    var cleanupCommand: String?
    var note: String?
    /// Set for groups measured as one number instead of a walk, like a container disk image.
    var fixedBytes: Int64?
    /// Container disks get `docker system df` output in their note. It is slow, so the scanner runs it in the background.
    var showsDockerUsage = false

    var isWalked: Bool { fixedBytes == nil && kind != .system }
}

/// Finds what to measure: repos and their worktrees under the roots, other folders there,
/// the usual developer caches, and container disk images.
struct Discovery {
    private struct CacheDefinition {
        var name: String
        var path: String
        var cleanup: String?
        var note: String?
    }

    let roots: [String]
    var repositories: [String] = []
    let home: String
    let git: GitInspector?
    var scratchpads = ClaudeScratchpads()

    func discover() -> [GroupSpec] {
        let childrenByRoot = roots.map { (root: realPath($0), children: directories(in: realPath($0))) }
        let rootChildren = childrenByRoot.flatMap(\.children)
        var specs = repositorySpecs(rootChildren + repositories.map(realPath))
        let claimed = Set(specs.flatMap(\.paths))
        let projects = childrenByRoot.flatMap { root, children in
            let folders = children.filter { !claimed.contains($0) }
            let offersDelete = offersFolderDelete(root: root, repositories: children.count - folders.count, folders: folders.count)
            return folders.map { projectSpec($0, offersDelete: offersDelete, root: root) }
        }
        let worktrees = specs.filter { $0.gitSeed != nil }.flatMap(\.paths)
        let fixed = cacheSpecs() + scratchpadSpecs(keeping: worktrees) + systemSpecs()
        let projectRoom = GroupSet.maxGroups - specs.count - fixed.count - 1
        specs += lumpOverflow(projects, room: projectRoom)
        specs += fixed
        return specs
    }

    private func directories(in root: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var rootInfo = stat()
        guard stat(root, &rootInfo) == 0 else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = root + "/" + name
            var info = stat()
            // Mounted volumes inside the root are skipped, like du -x.
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_dev == rootInfo.st_dev else { return nil }
            return path
        }
    }

    private func repositorySpecs(_ candidates: [String]) -> [GroupSpec] {
        guard let git else { return [] }
        let repos = candidates.filter { FileManager.default.fileExists(atPath: $0 + "/.git") }
        let lists = Locked([Int: [WorktreeEntry]]())
        DispatchQueue.concurrentPerform(iterations: repos.count) { index in
            let entries = git.worktrees(from: repos[index])
            lists.withLock { $0[index] = entries }
        }
        var seen = Set<String>()
        var specs: [GroupSpec] = []
        let ordered = lists.withLock { value in value.keys.sorted().compactMap { value[$0] } }
        for entries in ordered {
            guard let main = entries.first else { continue }
            let repoPath = realPath(main.path)
            for (index, entry) in entries.enumerated() {
                let path = realPath(entry.path)
                guard seen.insert(path).inserted else { continue }
                specs.append(worktreeSpec(path: path, entry: entry, repoPath: repoPath, isMain: index == 0))
            }
        }
        return specs
    }

    private func worktreeSpec(path: String, entry: WorktreeEntry, repoPath: String, isMain: Bool) -> GroupSpec {
        let name = (path as NSString).lastPathComponent
        let exists = FileManager.default.fileExists(atPath: path)
        var spec = GroupSpec(
            kind: isMain ? .mainCheckout : .worktree,
            name: name,
            paths: [path],
            classify: true,
            defaultKind: .source,
            gitSeed: GitSeed(repoPath: repoPath, worktreePath: path, branch: entry.branch, isMainCheckout: isMain),
            cleanupCommand: nil,
            note: nil
        )
        if !isMain {
            spec.cleanupCommand = "git -C \(shellQuote(repoPath)) worktree remove \(shellQuote(path))"
        }
        if !exists {
            spec.fixedBytes = 0
            spec.cleanupCommand = "git -C \(shellQuote(repoPath)) worktree prune"
            spec.note = "The folder is gone, but git still lists the worktree."
        }
        return spec
    }

    /// Folders a code folder holds next to its repositories are usually leftovers when there are
    /// few of them among many repositories, like an old copy in ~/workspace. Where there are many,
    /// or only a few repositories, they are more likely someone's own projects without git, so
    /// they are listed but never offered for deletion. Neither are folders in Documents, Desktop or
    /// Downloads, which hold everything else a person keeps.
    static let minRepositoriesForFolderDelete = 5
    static let maxFolderShareForFolderDelete = 0.25

    private func offersFolderDelete(root: String, repositories: Int, folders: Int) -> Bool {
        let personal = ["Documents", "Desktop", "Downloads"].map { realPath(home + "/" + $0) }
        guard !personal.contains(root), repositories >= Self.minRepositoriesForFolderDelete else { return false }
        return Double(folders) / Double(repositories + folders) <= Self.maxFolderShareForFolderDelete
    }

    private func projectSpec(_ path: String, offersDelete: Bool, root: String) -> GroupSpec {
        let rootName = (root as NSString).abbreviatingWithTildeInPath
        return GroupSpec(
            kind: .project,
            name: (path as NSString).lastPathComponent,
            paths: [path],
            classify: true,
            defaultKind: .source,
            gitSeed: nil,
            cleanupCommand: offersDelete ? "rm -rf \(shellQuote(path))" : nil,
            note: offersDelete ? nil : "Not offered for deletion: folders next to the repositories in \(rootName) are likely your own projects. Build output and caches inside can still go with Build Output."
        )
    }

    /// Folders past the group limit share one group, so every byte is still counted.
    private func lumpOverflow(_ projects: [GroupSpec], room: Int) -> [GroupSpec] {
        guard projects.count > room, room > 0 else { return projects }
        var kept = Array(projects.prefix(room - 1))
        let rest = projects.dropFirst(room - 1)
        kept.append(GroupSpec(
            kind: .project,
            name: "Other folders (\(rest.count))",
            paths: rest.flatMap(\.paths),
            classify: true,
            defaultKind: .source,
            gitSeed: nil,
            cleanupCommand: nil,
            note: "Grouped because the scan tracks at most \(GroupSet.maxGroups) groups."
        ))
        return kept
    }

    private func cacheSpecs() -> [GroupSpec] {
        let environment = ProcessInfo.processInfo.environment
        let uvCache = environment["UV_CACHE_DIR"] ?? "\(home)/.cache/uv"
        let definitions = pnpmStores() + [
            CacheDefinition(name: "uv cache", path: uvCache, cleanup: "uv cache clean",
                            note: "Virtualenvs hold copy-on-write clones, so they keep working after a clean."),
            CacheDefinition(name: "pnpm metadata cache", path: "\(home)/Library/Caches/pnpm",
                            cleanup: "rm -rf ~/Library/Caches/pnpm"),
            CacheDefinition(name: "npm cache", path: "\(home)/.npm", cleanup: "npm cache clean --force"),
            CacheDefinition(name: "Yarn cache", path: "\(home)/Library/Caches/Yarn", cleanup: "yarn cache clean"),
            CacheDefinition(name: "sccache", path: "\(home)/Library/Caches/Mozilla.sccache",
                            cleanup: "rm -rf ~/Library/Caches/Mozilla.sccache"),
            CacheDefinition(name: "Playwright browsers", path: "\(home)/Library/Caches/ms-playwright",
                            cleanup: "rm -rf ~/Library/Caches/ms-playwright",
                            note: "Reinstall the browsers you need with npx playwright install."),
            CacheDefinition(name: "Cypress binaries", path: "\(home)/Library/Caches/Cypress", cleanup: "npx cypress cache clear"),
            CacheDefinition(name: "Cargo registry", path: "\(home)/.cargo/registry", cleanup: "rm -rf ~/.cargo/registry"),
            CacheDefinition(name: "Cargo build output", path: environment["CARGO_TARGET_DIR"] ?? "\(home)/.cargo/target",
                            cleanup: "rm -rf ~/.cargo/target",
                            note: "Shared Cargo target folder, as the PostHog Flox env sets it. The next Rust build starts cold."),
            CacheDefinition(name: "Rust toolchains", path: "\(home)/.rustup", cleanup: nil,
                            note: "List toolchains with rustup toolchain list and uninstall the old ones."),
            CacheDefinition(name: "Go module cache", path: "\(home)/go/pkg/mod", cleanup: "go clean -modcache"),
            // Since PostHog/posthog#129556 every posthog worktree shares these instead of one copy in each .flox/cache.
            CacheDefinition(name: "PostHog Go modules", path: "\(home)/.cache/posthog/go",
                            cleanup: "chmod -R u+w ~/.cache/posthog/go && rm -rf ~/.cache/posthog/go",
                            note: "Shared by every posthog worktree. Go makes module folders read-only, so the command makes them writable first."),
            CacheDefinition(name: "PostHog Go build cache", path: "\(home)/.cache/posthog/go-build",
                            cleanup: "rm -rf ~/.cache/posthog/go-build",
                            note: "Shared by every posthog worktree. The next Go build fills it again."),
            CacheDefinition(name: "pip cache", path: "\(home)/Library/Caches/pip", cleanup: "pip cache purge"),
            CacheDefinition(name: "Homebrew downloads", path: "\(home)/Library/Caches/Homebrew", cleanup: "brew cleanup --prune=all"),
            CacheDefinition(name: "Hugging Face cache", path: "\(home)/.cache/huggingface", cleanup: nil,
                            note: "Downloaded models. Delete the ones you no longer use."),
            CacheDefinition(name: "Xcode DerivedData", path: "\(home)/Library/Developer/Xcode/DerivedData",
                            cleanup: "rm -rf ~/Library/Developer/Xcode/DerivedData"),
            CacheDefinition(name: "Gradle caches", path: "\(home)/.gradle/caches", cleanup: "rm -rf ~/.gradle/caches"),
        ]
        return definitions.compactMap { definition in
            guard FileManager.default.fileExists(atPath: definition.path) else { return nil }
            return GroupSpec(
                kind: .cache,
                name: definition.name,
                paths: [realPath(definition.path)],
                classify: false,
                defaultKind: .caches,
                gitSeed: nil,
                cleanupCommand: definition.cleanup,
                note: definition.note
            )
        }
    }

    /// One item for the scratch folders of finished Claude Code sessions. The command names each
    /// folder, so a session that is still running keeps its own.
    private func scratchpadSpecs(keeping worktrees: [String]) -> [GroupSpec] {
        let sessions = scratchpads.sessions(keeping: worktrees)
        guard !sessions.idle.isEmpty else { return [] }
        let days = Int(ClaudeScratchpads.idleTime / 86400)
        var note = "Scratch folders of \(sessions.idle.count) Claude Code sessions idle for \(days) days or more."
        if sessions.activeCount > 0 {
            note += " The \(sessions.activeCount) newer sessions keep theirs."
        }
        note += " A session that holds a git repository or worktree keeps its folder, since it may hold the only copy of commits."
        return [GroupSpec(
            kind: .cache,
            name: ClaudeScratchpads.itemName,
            paths: sessions.idle,
            classify: false,
            defaultKind: .caches,
            gitSeed: nil,
            cleanupCommand: "rm -rf " + sessions.idle.map(shellQuote).joined(separator: " "),
            note: note
        )]
    }

    /// pnpm keeps one store per layout version. Only the newest one is used by a current pnpm.
    private func pnpmStores() -> [CacheDefinition] {
        let storeRoots = ["\(home)/Library/pnpm/store", "\(home)/.local/share/pnpm/store"]
        var definitions: [CacheDefinition] = []
        for storeRoot in storeRoots {
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: storeRoot)) ?? [])
                .filter { $0.hasPrefix("v") && Int($0.dropFirst()) != nil }
                .sorted { Int($0.dropFirst())! < Int($1.dropFirst())! }
            for version in versions {
                let path = storeRoot + "/" + version
                let isNewest = version == versions.last
                definitions.append(CacheDefinition(
                    name: isNewest ? "pnpm store (\(version))" : "pnpm store (\(version), older pnpm)",
                    path: path,
                    cleanup: isNewest ? "pnpm store prune" : "rm -rf \(shellQuote(path))",
                    note: "node_modules hold copy-on-write clones, so installed projects keep working without the store."
                ))
            }
        }
        return definitions
    }

    private func systemSpecs() -> [GroupSpec] {
        var specs: [GroupSpec] = []
        let images = [
            ("OrbStack disk", "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img.raw"),
            ("OrbStack disk", "\(home)/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img"),
            ("Docker Desktop disk", "\(home)/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
        ]
        for (name, path) in images {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let allocated = Int64(info.st_blocks) * 512
            let note = "Sparse disk image: \(ByteFormat.string(allocated)) on disk, \(ByteFormat.string(Int64(info.st_size))) logical."
            specs.append(GroupSpec(
                kind: .system,
                name: name,
                paths: [path],
                classify: false,
                defaultKind: .caches,
                gitSeed: nil,
                cleanupCommand: "docker system prune",
                note: note,
                fixedBytes: allocated,
                showsDockerUsage: true
            ))
        }
        if let nixBytes = separateVolumeUsage("/nix") {
            specs.append(GroupSpec(
                kind: .system,
                name: "Nix store",
                paths: ["/nix"],
                classify: false,
                defaultKind: .caches,
                gitSeed: nil,
                cleanupCommand: "nix-collect-garbage -d",
                note: "Separate APFS volume that shares free space with your data volume.",
                fixedBytes: nixBytes
            ))
        }
        return specs
    }

    static func dockerUsage() -> String? {
        guard let docker = Shell.find("docker") else { return nil }
        let result = Shell.run(docker, ["system", "df", "--format", "{{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)"], timeout: 10)
        guard result.status == 0, !result.timedOut else { return nil }
        let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.isEmpty ? nil : lines
    }

    private func separateVolumeUsage(_ mountPoint: String) -> Int64? {
        var volume = statfs()
        var homeVolume = statfs()
        guard statfs(mountPoint, &volume) == 0, statfs(home, &homeVolume) == 0 else { return nil }
        let sameVolume = volume.f_fsid.val.0 == homeVolume.f_fsid.val.0 && volume.f_fsid.val.1 == homeVolume.f_fsid.val.1
        guard !sameVolume else { return nil }
        return volumeSpaceUsed(mountPoint)
    }

    /// statfs reports the whole APFS container, which every volume shares. ATTR_VOL_SPACEUSED is per volume.
    private func volumeSpaceUsed(_ mountPoint: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 32)
        guard getattrlist(mountPoint, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }
}
