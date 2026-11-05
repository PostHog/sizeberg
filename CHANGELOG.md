# Changelog

## 0.1.4 (unreleased)

- Clean Up skips a worktree or folder that any running process works in, such as a dev server, an editor or a terminal tab, and names it. Before, only Claude Code and Codex agents kept a worktree.
- The cleanup sheet names files git ignores that deleting a worktree would lose, such as `.env.local` or notes, with secret-looking ones in orange. `git worktree remove` deletes those without asking. Rebuildable tool output and files identical to the main checkout's copy are left out.
- The shared Go caches that hogli moved to `~/.cache/posthog/go` and `go-build` show up as cache items.

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
