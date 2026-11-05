# Changelog

## 0.1.0

First release.

- Shows what deleting each worktree, folder and cache really frees on APFS, where `du` and Finder count every copy-on-write clone in full.
- Worktrees sit under their main checkout, with their git state: local work, merged, remote branch gone. Select Stale picks the stale ones without local work.
- "Build output and caches" deletes build output and in-repo caches from items that stay, and leaves dependencies, folders git tracks and folders under 1 MB.
- Clean Up runs the plan after a confirmation that lists every item, and checks each worktree and folder again right before deleting it.
- Rescans read only the folders FSEvents reports as changed.
- Updates itself through Sparkle when signed with PostHog's Developer ID; `brew upgrade --cask sizeberg` otherwise.
