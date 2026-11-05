# SizeBerg

Shows what deleting worktrees, dependencies, build output and caches really frees on a Mac.

On APFS, pnpm and uv install packages as copy-on-write clones. `du`, Finder and most cleaners count every clone at full size, so a worktree's `node_modules` looks like gigabytes but frees almost nothing. The real bytes sit in the shared stores, in build output, and in folders nobody uses any more. Like an iceberg, most of what you see is not what you get.

## Install

```sh
brew install --cask posthog/tap/sizeberg
```

That installs `SizeBerg.app` and the `sizeberg` command. It needs macOS 26 or later on Apple silicon.

- **Updates**: releases signed with PostHog's Developer ID update themselves through [Sparkle](https://sparkle-project.org): SizeBerg checks once a day, and SizeBerg › Check for Updates… checks now. Builds that are not signed that way, such as local ones, update with `brew upgrade --cask sizeberg`.
- **Uninstall**: `brew uninstall --zap sizeberg` removes the app, the command, the scan cache in `~/Library/Caches/sizeberg` and the settings. Without Homebrew, delete the app and those folders by hand; the cask's `zap` list in `homebrew/sizeberg.rb.tmpl` names each path.

## Build and run

```sh
./build.sh                     # macOS 26 or later; the command line tools are enough, Xcode works too
open build/SizeBerg.app        # SwiftUI window with table, treemap and cleanup plan
build/sizeberg                 # text summary (the same CLI is in SizeBerg.app/Contents/Helpers)
build/sizeberg --plan          # cleanup commands for stale worktrees and stores (runs nothing)
build/sizeberg --json          # full report
build/sizeberg --clear-cache   # forget earlier scans; the app has Clear Cache (⌥⌘R)
SDKROOT=$(xcode-select -p)/SDKs/MacOSX26.sdk swift test   # accounting, scoring and change-tracking tests
```

Both write the last scan to `~/Library/Caches/sizeberg/last-scan.json`, and the app opens on it.

The app is a plain SwiftUI split view: filters in the sidebar, the list or the map in the middle, the selected item in the inspector, and the cleanup plan in a bar under the list. Worktree rows show their git state in front of the branch: local work, merged, or remote branch gone. With the command line tools it builds against their macOS 26 SDK, because the macOS 27 SDK makes `@State` a macro whose plugin ships only with Xcode. macOS 27 restyles the glass at run time either way.

The app is about 3.5 MB, the download about 1.8 MB. While a rescan runs it uses up to about 600 MB of memory for the cached file entries, then drops back to about 130 MB.

See [RELEASING.md](RELEASING.md) for how releases are built, signed and published.

## What it scans

- Wherever you keep your code: SizeBerg walks your home folder for the first folders that hold git repositories, like `~/workspace` or `~/Documents/GitHub`, and scans each of them whole. A repository right in your home folder, like `~/dotfiles`, is an item of its own. It skips `~/Library`, hidden folders, media folders and dependency trees. `--root` scans given folders instead. If your repositories are in Documents, Desktop or Downloads, macOS asks once whether SizeBerg may read that folder.
- Git repos and all their worktrees, also ones outside those folders, get branch, last use, merged and remote-gone state, squash merges, uncommitted changes and unpushed commits.
- Developer caches: pnpm stores (each layout version), uv, npm, Yarn, sccache, Playwright, Cargo, Go, pip, Homebrew and more.
- Container disks (OrbStack, Docker Desktop) and the Nix store volume, as single numbers.

Inside each folder, files land in buckets: dependencies (`node_modules`, venvs), build output (`target`, `dist`, `.mypy_cache`, ...), caches, git data, and the rest.

"Build output and caches" is one item in the list for the build output and in-repo caches of every checkout, worktree and folder that stays. Deleting it leaves the items, their source and their dependencies; the next build puts the folders back. Folders that hold files git tracks stay, and so do folders under 1 MB: a Python tree has one small `__pycache__` per package, thousands of deletes for little space.

## Speed

Measured on an M-series MacBook with 18 million files in the scanned folders.

- **First scan**: 80 to 90 seconds when macOS still has much of the file metadata in memory, up to about 3 minutes after a restart. Reading that much metadata is the floor: even a catalog scan of the whole volume with `searchfs` takes about 2 minutes.
- **Useful numbers early**: caches, build output, git data and source are read first, dependency trees last. Dependency trees hold half the files but little of what deleting frees. While the scan runs, each item shows "at least" what is certain so far. Once its last folder is read it says Final: the clone copy count tells whether every copy is inside the item, so its number is exact without waiting for the rest. On the test machine, 77% of the final total showed after 25 seconds and 95% after 37 seconds of an 80 second scan.
- **Rescans**: about 3 to 6 seconds. They ask the FSEvents history which folders changed since the last scan and walk only those. Each top-level folder of a worktree or cache is cached on its own, so an edit in `frontend/src` re-walks `frontend`, not `node_modules`.
- **Progress**: rescans and full scans show a share and time left, from the last scan's file counts. A first scan shows folders done and time spent. A full scan shows the live table with the last scan's numbers as dashed bars.
- The cache lives in `~/Library/Caches/sizeberg/groups` (about 250 MB for 18 million files). `--full`, or Full Scan in the app, ignores it. A worktree that did not change since the last scan keeps its `git status` answer, so rescans do not read big worktrees again.
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
- A rescan asks APFS again for the copy count of files whose clones were in changed or deleted folders, and of every file that claims to be the only copy, so a clone made outside the scanned folders never makes a file look freeable. A copy deleted outside the scanned folders goes unnoticed until a full scan: its siblings then count as shared, never as freeable. This costs about a second per rescan.
- "Stale" means quiet for 3 days with merged or remote-gone work, or quiet for 21 days. It is a hint; the detail panel shows why.
- Clean Up runs the plan's commands after a confirmation that lists every item and command. Deleted files skip the Trash: clones in the Trash would keep their blocks. Each worktree is checked again right before: one with uncommitted changes, commits no remote has (squash merges count as merged), or any running process in it is skipped, and the sheet names files git ignores that deleting it would lose. Commands run in a login shell, the way Terminal would run them. Container disks stay manual. Copy commands still copies the plan instead.

## Tried and dropped

Ideas that did not hold up on a real machine, so nobody has to try them again.

- **`searchfs` catalog scan**: whole volume in 113 seconds on one thread, names and ids only. APFS rejects the attributes the scan needs there.
- **Random-descent estimate of the file count** (Knuth's estimator), for a progress share on a first scan: off by -72% to +511% with a 10 second budget. Dependency trees are too uneven.
- **Recursive generation counts** (`ATTR_CMNEXT_RECURSIVE_GENCOUNT`) to check cached folders without FSEvents: always 0 unless a folder keeps directory statistics, which almost none do.
- **Spotlight**: logical sizes only, no clone data, and it skips most dependency folders.
- **Sampling dependency trees** (Horvitz-Thompson over package folders, 132,000 folders, 300 seeds): reading 5% gives the file count and du within about ±13% with honest intervals, but the bytes that decide what deleting frees sit in a few packages, and the 95% intervals hold the truth only about half the time. Sampling by package name across worktrees is worse. Dependency trees are read last and free little, so the full read stays.
- **Monte Carlo ranges during a first scan** (where missing clone copies turn up, sibling folders as stand-ins for unread ones): a replay of a traced scan shows the unknown sits in folders not read yet, at 25 seconds 61 GB in one folder. Siblings can stand in for an unread folder only after about 45 seconds, when 2.6 GB is left.
- **Background priority**: `taskpolicy -b` keeps a foreground `git status` near its idle speed (62 ms against 56 ms) but makes the scan 4 times slower; utility priority is slower and still disturbs. Scans run at normal priority.
- **Thread count and buffer size**: 4 threads are 30% slower than 8, 12 gain nothing; buffer size makes no difference. See `Walker.workerCount` and `BulkReader`.
