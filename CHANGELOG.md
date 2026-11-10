# Changelog

## Unreleased

- New "Agent waste" filter for what coding agents and their tools leave outside checkouts. Each kind of waste is one row, with its items below it, the way a main checkout holds its worktrees:
  - Claude Code scratchpads: a session that a process uses gets a row of its own, with that process named. Idle sessions that can go make one row per project. A session can go after a day without changes (was 3 days), when no process works in its folder or has a file open there.
  - Leftover temp folders: folders in `/tmp` and `$TMPDIR` with a generated name, like Python's `tmpk3x_9a1b` or mktemp's `tmp.Ab12Cd34`, grouped by name. Killed or crashed runs never remove them. They can go after 6 hours without changes and with no process using them.
  - Tool caches in temp folders: folders marked with `CACHEDIR.TAG` in `~/.cache` and the temp folders, such as a Cargo target folder per agent run.
  - The rest of `/tmp`, `$TMPDIR` and the Claude Code transcripts, for their size only.
- The check for a process in a folder now also finds processes with a file open there, not only ones whose current folder it is.
- The scan cache moved to `~/Library/Application Support/SizeBerg`, so cleaners that empty `~/Library/Caches`, like Mole, no longer force a full rescan. The old folder moves over on first start.
- "Group worktrees under main checkout" is now "Group worktrees and agent waste".
- The Cleanup column shows a verdict instead of five dots: Safe, Likely, Recent, In use or Risky, after what deleting would lose. Size stays in its own column, and the list still sorts by size weighted by how sure the scan is.
- The cleanup bar shows what the review sheet will delete, on the Delete button itself. Selected items the app does not delete itself show as "need you", with the reason and a way to deselect them.
- Deleting agent waste checks every folder of an item again, even when the first one is already gone, and looks at every file inside for recent changes and sockets. Folders go in batches, so an item with thousands of temp folders no longer fails on the shell's argument limit. A file that Docker or OrbStack holds open in a temp folder keeps it.

## 0.1.7

- A worktree whose only untracked files are symlinks, such as the `node_modules` links agent tools put into each worktree, no longer counts as having uncommitted changes. An ignore rule like `node_modules/` matches folders only, so git lists those links. Delete removes the links first, never what they point to, and then runs `git worktree remove` as before.
- Background helpers such as OrbStack and Docker Desktop no longer keep a worktree or folder from being deleted. They keep the current folder of the terminal they were first started from, for days, without working there.
- A test makes sure the check for uncommitted changes leaves the git index untouched, because its modification time is what tells when a worktree was last used.

## 0.1.6

- Folders next to your repositories are offered for deletion only where they look like leftovers: in a code folder with at least 5 repositories, where plain folders are at most a quarter of what it holds. Elsewhere, such as a few repositories with your own projects beside them, or anything in Documents, Desktop or Downloads, they are listed with their size but not offered. Build output and caches inside them can still go with Build Output.
- A plain folder that holds git repositories or worktrees, such as a folder you keep worktrees in, is never offered for deletion, and Delete checks for git data at any depth first. Before, `rm -rf` on such a folder would have deleted those worktrees without the checks for uncommitted and unpushed work.

## 0.1.5

- A squash-merge match must also merge into the squash commit without changing it. Patch ids leave out where a change sits, so an edit moved to another block could still count as merged.
- The GitHub check only counts pull requests merged into the default branch. A stacked pull request merged into a branch that never reached it no longer makes its worktree look merged.

## 0.1.4

- Runs on macOS 15 Sequoia. Liquid Glass buttons and the toolbar spacer sit behind availability checks, so Sequoia shows the classic look. CI now launches each build on a macOS 15 runner and scans a test repository there.
- Clean Up skips a worktree or folder that any running process works in, such as a dev server, an editor or a terminal tab, and names it. Before, only Claude Code and Codex agents kept a worktree.
- The cleanup sheet names files git ignores that deleting a worktree would lose, such as `.env.local` or notes, with secret-looking ones in orange. `git worktree remove` deletes those without asking. Rebuildable tool output and files identical to the main checkout's copy are left out.
- The shared Go caches that hogli moved to `~/.cache/posthog/go` and `go-build` show up as cache items.
- Claude Code scratchpads in `/private/tmp/claude-<uid>` show up as one item, for sessions idle for 3 days or more. A running session keeps its scratch folder, and so does a session that holds a git clone or worktree, which may hold the only copy of its commits. Delete checks each folder again first.
- Clean Up asks git for untracked files explicitly. With `status.showUntrackedFiles=no` set, a worktree with new, never-added files looked clean, and `git worktree remove` deleted them.
- Build output in a plain folder that holds a repository, or in a clone inside a checkout, is checked against that repository, so folders with files git tracks stay there too.
- Squash-merge matching keeps whitespace, so a re-indent committed after the merge counts as new work.

## 0.1.3

- Finds your code wherever it lives. Scans looked only in `~/workspace`; now SizeBerg walks your home folder for the first folders that hold git repositories, like `~/code` or `~/Documents/GitHub`, and repositories right in your home folder, like `~/dotfiles`. It skips `~/Library`, hidden folders, media and dependency trees, and the walk adds about a second to a scan. `sizeberg --root` still scans given folders instead.

## 0.1.2

- Squash-merged branches count as merged. The merge queue rewrites a pull request's commits into one, so git called them unmerged and unpushed, and those worktrees stayed "stale, local work". SizeBerg now finds the squash commit offline by comparing patch ids, and asks GitHub through `gh`, when it is installed and logged in, for a merged pull request that contains the worktree's HEAD. Clean Up checks the same again right before it deletes, so a commit made after the merge still keeps the worktree.
- Clean Up opens while a scan runs; only Delete waits for the scan to finish, and says so, instead of a disabled button.

## 0.1.1

- The list stays current: SizeBerg rescans when it opens and when you come back to it after a few minutes, instead of showing the last scan until you press ⌘R.
- Items a cleanup deleted leave the list at once. The rescan after a big delete can take a minute, because every shared file the deleted items held is counted again.
- A rescan keeps your selection, the item in the inspector and folded repositories, by path. Items that are gone drop out.

## 0.1.0

First release.

- Shows what deleting each worktree, folder and cache really frees on APFS, where `du` and Finder count every copy-on-write clone in full.
- Worktrees sit under their main checkout, with their git state in front of the branch: local work, merged, remote branch gone. Select Stale picks the stale ones without local work.
- An Agent column shows where a Claude Code or Codex agent is working, or worked in the last 3 days, including subagents in their own worktrees. A worktree with an agent at work keeps a cleanup value of zero, stays out of Select Stale, and Clean Up skips it.
- "Build output and caches" deletes build output and in-repo caches from items that stay, and leaves dependencies, folders git tracks and folders under 1 MB.
- Clean Up runs the plan after a confirmation that lists every item, and checks each worktree and folder again right before deleting it.
- Rescans read only the folders FSEvents reports as changed.
- Updates itself through Sparkle when signed with PostHog's Developer ID; `brew upgrade --cask sizeberg` otherwise.
