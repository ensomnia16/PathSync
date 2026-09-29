# PathSync

A small macOS app for syncing local working folders with mounted cloud folders on a schedule. It is useful when local builds, such as LaTeX, create many short-lived files.

## Features

- Manage multiple folder pairs. Each pair has its own sync direction: two-way merge, local to cloud, or cloud to local.
- Each pair can independently include Codex project files (`AGENTS.md`, `.codex/`, `.agents/`), Claude Code project files (`CLAUDE.md`, `.claude/`, `.mcp.json`), and temporary files such as `tmp`, `.tmp`, `.log`, and generated working directories. Machine-local `.claude/settings.local.json` and `.DS_Store` are always skipped. Pairs without a saved filter setting skip temporary files by default; existing copies and anchors remain and are never treated as deletions.
- Optionally share configuration through iCloud Drive on Macs signed in with the same Apple ID. Saving publishes pair names, rules, and paths relative to each Mac's chosen local working and OneDrive roots. The local working root defaults to `~/Documents`; import derives local paths and creates missing empty folders after preview. For older profiles without local relative paths, it derives them from the OneDrive relative paths. Absolute paths, enabled state, history, backups, and synced file contents are not included. New pairs remain disabled until reviewed. Local edits to shared rules are flagged before replacement; saved configurations can be rolled back from local snapshots.
- Set a shared default schedule: any daily time or an interval from 6 to 168 hours.
- Use the menu bar to see the pending review count, sync all folders, or reopen the main window or History after closing it.
- The app runs from the menu bar without a running Dock icon. Quitting the UI does not disable the installed sync schedule.
- Enable Launch at login in Settings → General to register a macOS login item. This is separate from the scheduled sync task.
- Choose notifications for conflicts or failures, every completed run, or off. Notifications are off by default; enabling them requests macOS permission. Notification text contains no file names or paths.
- Use the prominent Sync now button for all enabled folders or the selected pair; explicit merge, upload, and download actions remain available.
- Read past runs in the History page, with time, folder, direction, counts, and expandable conflict or failure details. Open or reveal affected files in Finder. For LaTeX text, compare current versions with an offline diff and line/section summary, or explicitly ask the installed Codex CLI to summarize the selected diff. Filter by folder or result; the raw log remains available for troubleshooting.
- By default, divergent files keep both versions automatically. Both originals are backed up locally before either synced folder changes. A preserved copy remains flagged for review on every subsequent run until you explicitly acknowledge it. You can choose to pause for a manual decision instead.
- Conflicts are measured against the last common content anchor. When both sides changed, you may also choose the version with the later absolute modification time; equal timestamps pause for manual review.
- Deletes and edits are compared with the same last common anchor. A one-sided change propagates in the chosen direction; a concurrent edit and delete remains a conflict. The remaining file is backed up before this tool deletes it.
- If one side deletes a previously synced folder while the other changes files inside it, the whole subtree pauses. Make the two folders agree manually and refresh conflicts; unrelated files continue syncing.
- Every actual overwrite or propagated deletion has a verified local backup with a Restore button in History. Backups default to 15 days and are cleaned on a later sync; the retention period is configurable.
- The app refreshes pending conflicts when brought forward and while open; you can refresh them manually as well.
- OneDrive scans now show folder and file progress. Large first-time cloud imports hydrate at most four files at once and copy smaller new files first. Each cloud read has a size-based 120–300 second limit with visible wait updates; a failed file is recorded while other files continue. A pair with no progress for three minutes is stopped. File Provider ctime changes and subsecond mtime rounding no longer trigger a full reread of unchanged files; explicit changes still cause both sides to be hashed before a write.
- LaTeX build files, virtual environments, and common caches can be excluded.
- Switch the interface between Simplified Chinese, English, and the system language.
- Updates: the app checks GitHub for packaged releases at launch and at most once a day, or on request. A release with a signed archive can be installed and relaunched in the app; automatic installation is optional in About. The archive is verified with a pinned Ed25519 public key before replacement. Version 2.14.1 needs a one-time manual upgrade to gain in-app installation. Unreleased main commits are not app updates, and checks send no file names or paths.

## Download and build

[Download the Apple Silicon app](https://github.com/ensomnia16/PathSync/releases/tag/v2.15.3) for macOS 13 or later. The app is not notarized by Apple.

To build locally, install Xcode Command Line Tools and run `./build.sh`. Copy the resulting `.build/路径同步.app` into `/Applications`, select folders, and save settings. The saved schedule runs through a per-user macOS LaunchAgent while you are signed in.

The interface uses native SwiftUI sidebar, form, and toolbar controls. Overview shows overall status, the last sync, the schedule interval or next fixed time, and a card per folder pair; each folder page edits its paths, direction, and conflicts; Settings groups schedule, conflicts and backups, filtering, notifications, and language. Unsaved changes are shown in the status bar. The selected blue icon uses a single-axis, two-way arrow. Its generated source image is `PathSyncIcon.png`.

To share settings, turn on iCloud configuration in Settings, select this Mac's OneDrive root, and save. Each Mac publishes a separate snapshot in iCloud Drive at `PathSync/Configuration/<device UUID>.json`. On another Mac, select its OneDrive root and save before importing a snapshot. Review the derived cloud paths, choose local work folders for new pairs, and save again. New or rebound pairs stay disabled until reviewed. A remote deletion never silently removes a local pair. Scheduled file sync reads only this Mac's saved configuration; it does not import remote changes in the background.

The [synchronization model](docs/synchronization-model.md) records the primary sources, state transitions, and current limits around directory conflicts and OneDrive availability.

For an already preserved conflict, “Use newer current version” compares the current main file and preserved copy. The preserved copy must match across both folders. If the main files differ, the action can first back up and propagate a change made on just one side relative to the anchor. Changes on both sides still pause. Inspect the newer file before using the date-based action.

Starting with 2.11.0, there is no separate deletion-propagation switch. The old `propagateDeletions` configuration field is ignored when loading and removed on the next save. Use `--dry-run` to preview actions on existing folders after upgrading.

In two-way merge and upload, the local version remains at the original path while a labeled cloud copy appears in both folders. In download, the cloud version remains at the original path and a labeled local copy appears in both folders. Backups are stored under `~/Library/Application Support/ResearchSync/merge-state/`. Keeping both preserves content but does not merge it into the original file. Review the two versions and explicitly acknowledge when finished; the copy and backup remain. Manual conflicts stay pending until resolved; if either original changes after listing, sync again before choosing a version.

History reads the existing `sync.log`, so older runs remain visible. It shows records for currently configured folder pairs, loading up to the last 2 MB of the log and displaying the newest 200 runs. Ordinary transfers show counts; conflicts and failures include filenames.
