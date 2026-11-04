# SizeBerg

Shows what deleting worktrees, dependencies, build output and caches really frees on a Mac.

On APFS, pnpm and uv install packages as copy-on-write clones. `du`, Finder and most cleaners count every clone at full size, so a worktree's `node_modules` looks like gigabytes but frees almost nothing. The real bytes sit in the shared stores, in build output, and in folders nobody uses any more. Like an iceberg, most of what you see is not what you get.

## Build and run

```sh
./build.sh                     # needs the Xcode command line tools, not Xcode
open build/SizeBerg.app        # SwiftUI window with table, treemap and cleanup plan
build/sizeberg                 # text summary
build/sizeberg --plan          # cleanup commands for stale worktrees and stores (runs nothing)
build/sizeberg --json          # full report
build/sizeberg --clear-cache   # forget earlier scans; the app has Clear Cache (⌥⌘R)
swift test                     # accounting and change-tracking tests
```

Both write the last scan to `~/Library/Caches/sizeberg/last-scan.json`, and the app opens on it.

## What it scans

- Every folder in `~/workspace` (change with `--root`). Git repos and all their worktrees, also ones outside the root, get branch, last use, merged and remote-gone state, uncommitted changes and unpushed commits.
- Developer caches: pnpm stores (each layout version), uv, npm, Yarn, sccache, Playwright, Cargo, Go, pip, Homebrew and more.
- Container disks (OrbStack, Docker Desktop) and the Nix store volume, as single numbers.

Inside each folder, files land in buckets: dependencies (`node_modules`, venvs), build output (`target`, `dist`, `.mypy_cache`, ...), caches, git data, and the rest.

## Speed

Measured on an M-series MacBook with 18 million files in the scanned folders.

- **First scan**: 80 to 90 seconds when macOS still has much of the file metadata in memory, up to about 3 minutes after a restart. Reading that much metadata is the floor: even a catalog scan of the whole volume with `searchfs` takes about 2 minutes.
- **Useful numbers early**: caches, build output, git data and source are read first, dependency trees last. Dependency trees hold half the files but little of what deleting frees. Each folder shows "frees at least" while the scan runs: files that share no blocks with anything count as soon as they are read. On the test machine, 90% of the final total showed after 37 seconds of an 89 second scan (78 seconds in plain depth-first order).
- **Rescans**: about 5 seconds. They ask the FSEvents history which folders changed since the last scan and walk only those. Each top-level folder of a worktree or cache is cached on its own, so an edit in `frontend/src` re-walks `frontend`, not `node_modules`.
- **Progress**: rescans and full scans show a share and time left, from the last scan's file counts. A first scan shows folders done and time spent.
- The cache lives in `~/Library/Caches/sizeberg/groups` (about 250 MB for 18 million files). `--full`, or Full Scan in the app, ignores it.
- The scan turns off access time updates for its own reads, so reading folders writes no metadata.

## How the numbers work

- `getattrlistbulk` reads each directory with the clone id, the "may share blocks" flag and the clone reference count of every file. The reference count is the number of full clones of the file's data on the volume, the file included.
- Files that share blocks are grouped into clone families by volume and clone id. A family whose reference count is higher than the members found has copies outside the scan, so its blocks never count as freeable.
- Full clones share every block, so a complete family is all shared data. Only the last full clone of its data needs APFS's private size (blocks only this file holds), read by inode through `/.vol` and cached. Asking APFS for private size on every file would double the scan time.
- **du says**: allocated blocks, hard links counted once. What `du -sh` prints.
- **Frees alone**: private bytes, plus shared blocks whose every copy is inside the item.
- **Shared sets**: shared blocks are grouped by the exact set of items that hold a copy. A selection frees a set only when it contains all of them. So removing three worktrees plus `uv cache clean` is computed exactly, without double counting.
- A hard link seen fewer times than its link count has a link outside the scan. A hard-linked file that is also a clone counts as shared with something outside. Neither counts as freeable.

## Limits

- Local Time Machine snapshots keep old blocks, so files read as shared and deletes free less. The app warns when snapshots exist.
- A clone that was changed after cloning gets a new clone id but can still share blocks with its old family. The scan then counts its shared part as held outside the scan, and can overstate what deleting the rest of the old family frees. On the test machine 1 of 281,000 single clones was such a file.
- Copies outside the scanned folders are not known by name, only detected.
- "Stale" means quiet for 3 days with merged or remote-gone work, or quiet for 21 days. It is a hint; the detail panel shows why.
- Commands are copied, never run.

## Tried and dropped

Ideas that did not hold up on a real machine, so nobody has to try them again. Notes, probes and raw numbers are in `docs/research/`.

- **`searchfs` catalog scan**: whole volume in 113 seconds on one thread, names and ids only. APFS rejects the attributes the scan needs there.
- **Random-descent estimate of the file count** (Knuth's estimator), for a progress share on a first scan: off by -72% to +511% with a 10 second budget. Dependency trees are too uneven.
- **Recursive generation counts** (`ATTR_CMNEXT_RECURSIVE_GENCOUNT`) to check cached folders without FSEvents: always 0 unless a folder keeps directory statistics, which almost none do.
- **Spotlight**: logical sizes only, no clone data, and it skips most dependency folders.
- **Sampling dependency trees** (Horvitz-Thompson over package folders, 132,000 folders, 300 seeds): reading 5% gives the file count and du within about ±13% with honest intervals, but the bytes that decide what deleting frees sit in a few packages, and the 95% intervals hold the truth only about half the time. Sampling by package name across worktrees is worse. Dependency trees are read last and free little, so the full read stays.
- **Monte Carlo ranges during a first scan** (where missing clone copies turn up, sibling folders as stand-ins for unread ones): a replay of a traced scan shows the unknown sits in folders not read yet, at 25 seconds 61 GB in one folder. Siblings can stand in for an unread folder only after about 45 seconds, when 2.6 GB is left.
- **Background priority**: `taskpolicy -b` keeps a foreground `git status` near its idle speed (62 ms against 56 ms) but makes the scan 4 times slower; utility priority is slower and still disturbs. Scans run at normal priority.
- **Thread count and buffer size**: 4 threads are 30% slower than 8, 12 gain nothing; buffer size makes no difference. See `Walker.workerCount` and `BulkReader`.
