# PathSync

A small macOS app for syncing local working folders with mounted cloud folders on a schedule. It is useful when local builds, such as LaTeX, create many short-lived files.

## Features

- Manage multiple folder pairs. Each pair has its own sync direction: two-way merge, local to cloud, or cloud to local.
- Set a shared default schedule: any daily time or an interval from 6 to 168 hours.
- Use the prominent Sync now button for all enabled folders or the selected pair; explicit merge, upload, and download actions remain available.
- Read past runs in the History page, with time, folder, direction, counts, and expandable conflict or failure details. Filter by folder or result; the raw log remains available for troubleshooting.
- By default, divergent files keep both versions automatically. Both originals are backed up locally before either synced folder changes. A preserved copy remains flagged for review on every subsequent run until you explicitly acknowledge it. You can choose to pause for a manual decision instead.
- Conflicts are measured against the last common content anchor. When both sides changed, you may also choose the version with the later absolute modification time; equal timestamps pause for manual review.
- Deletes and edits are compared with the same last common anchor. A one-sided change propagates in the chosen direction; a concurrent edit and delete remains a conflict. The remaining file is backed up before this tool deletes it.
- If one side deletes a previously synced folder while the other changes files inside it, the whole subtree pauses. Make the two folders agree manually and refresh conflicts; unrelated files continue syncing.
- Every actual overwrite or propagated deletion has a verified local backup with a Restore button in History. Backups default to 15 days and are cleaned on a later sync; the retention period is configurable.
- The app refreshes pending conflicts when brought forward and while open; you can refresh them manually as well.
- LaTeX build files, virtual environments, and common caches can be excluded.
- Switch the interface between Simplified Chinese, English, and the system language.

## Download and build

[Download the Apple Silicon app](https://github.com/ensomnia16/PathSync/releases/tag/v2.11.1) for macOS 13 or later. The app is not notarized by Apple.

To build locally, install Xcode Command Line Tools and run `./build.sh`. Copy the resulting `.build/路径同步.app` into `/Applications`, select folders, and save settings. The saved schedule runs through a per-user macOS LaunchAgent while you are signed in.

The interface uses native SwiftUI sidebar, form, and toolbar controls. The selected blue icon uses a single-axis, two-way arrow. Its generated source image is `PathSyncIcon.png`.

The [synchronization model](docs/synchronization-model.md) records the primary sources, state transitions, and current limits around directory conflicts and OneDrive availability.

For an already preserved conflict, “Use newer current version” compares the current main file and preserved copy. The preserved copy must match across both folders. If the main files differ, the action can first back up and propagate a change made on just one side relative to the anchor. Changes on both sides still pause. Inspect the newer file before using the date-based action.

Starting with 2.11.0, there is no separate deletion-propagation switch. The old `propagateDeletions` configuration field is ignored when loading and removed on the next save. Use `--dry-run` to preview actions on existing folders after upgrading.

In two-way merge and upload, the local version remains at the original path while a labeled cloud copy appears in both folders. In download, the cloud version remains at the original path and a labeled local copy appears in both folders. Backups are stored under `~/Library/Application Support/ResearchSync/merge-state/`. Keeping both preserves content but does not merge it into the original file. Review the two versions and explicitly acknowledge when finished; the copy and backup remain. Manual conflicts stay pending until resolved; if either original changes after listing, sync again before choosing a version.

History reads the existing `sync.log`, so older runs remain visible. It shows records for currently configured folder pairs, loading up to the last 2 MB of the log and displaying the newest 200 runs. Ordinary transfers show counts; conflicts and failures include filenames.
