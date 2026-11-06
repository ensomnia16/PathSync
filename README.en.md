# PathSync

Symbolic links are excluded from file sync. When a previously synced file or directory becomes a link, both sides of that path and its descendants are skipped, preserving existing copies and anchors without following the link or propagating deletion. Skipped paths appear in preview and history; restoring an ordinary file resumes comparison against the original anchor.

A small macOS app for syncing local working folders with mounted cloud folders on a schedule. It is useful when local builds, such as LaTeX, create many short-lived files.

## Features

- Manage multiple folder pairs. Each pair has its own sync direction: two-way merge, local to cloud, or cloud to local.
- Each pair can independently include Codex project files (`AGENTS.md`, `.codex/`, `.agents/`), Claude Code project files (`CLAUDE.md`, `.claude/`, `.mcp.json`), and temporary files such as `tmp`, `.tmp`, `.log`, and generated working directories. Machine-local `.claude/settings.local.json` and `.DS_Store` are always skipped. Pairs without a saved filter setting skip temporary files by default; existing copies and anchors remain and are never treated as deletions.
- Set a shared default schedule: any daily time or an interval from 1 to 168 hours.
- Enter one custom exclusion rule per line. Rules support `*`, `?`, and `**` globs. A trailing `/` matches folders, a leading or middle `/` anchors the rule at the pair root, and `#` starts a comment. Adding an exclusion preserves existing copies and sync anchors on both sides.
- Select this Mac's OneDrive root under Settings → OneDrive exclusions. When a pair's destination is under that root, PathSync automatically shares its filters through `PathSync-Exclusions.json` in that root. Each destination's relative path identifies its custom rules and its Codex, Claude, and temporary-file switches. The LaTeX build-file switch is also shared through OneDrive. Choose Save settings to publish changes. On another Mac with the same OneDrive root and destination folder configured, PathSync reads the shared rules at startup, during periodic refresh, and before preview or sync. PathSync pauses the preview or sync and reports the error if it cannot read the shared rules.
- On first migration, PathSync combines the app's custom rules with the `.pathsyncignore` files at both ends of the pair. After confirming the shared write, PathSync uses the OneDrive rules for those pairs. Local paths, sync directions, enabled states, history, and anchors stay on each Mac.
- For pairs outside OneDrive, place a UTF-8 `.pathsyncignore` at either pair root. Each preview and sync combines both root files with the app's rules. The rule file always follows the pair's sync direction and conflict policy. Cloud rules apply before the first download. An unreadable file, invalid UTF-8, a symlink, or a file larger than 1 MiB stops the pair. Preview asks you to download an online-only rule file first. The following rules exclude common caches and a specific rendering folder.

  ```gitignore
  # Reproducible files for this pair
  python-deps/
  .cache/
  *.partial
  /presentation-work/rendered/
  ```
- Cloud folder check (on by default in Settings): for folders in `~/Library/CloudStorage`, if OneDrive isn't running or the folder doesn't respond within 20 seconds, the pair is skipped this time with the reason in History, and unreadable files are never treated as deletions. Online-only placeholders whose content must be compared are downloaded first within the existing read limits; preview only counts them and never triggers downloads.
- Preview a sync from the overview, the toolbar, or a folder's page. It lists planned uploads, downloads, deletions (backed up first), conflicts, and unreadable files per folder, without writing anything or downloading online-only OneDrive files. Confirm to run the same sync. Scheduled sync never waits for a preview.
- Up to three folder pairs sync at once under the single sync lock. Conflict state and the log are read in the background, and the log incrementally.
- Backups can stay on this Mac (default), go to iCloud Drive (`PathSync/Backups/<pair ID>`), or to a chosen folder such as OneDrive. Each backup is verified after writing. If the location is unavailable, the backup stays on this Mac and moves on a later sync. Restore and cleanup look in both places. The folder can't be inside or contain a sync folder. “Move existing backups” copies, verifies, then removes the local copies. Merge state always stays on this Mac.
- The app opens in a standalone window and stays in the menu bar. Closing the main window keeps the app running and hides it from the Dock. Use the menu bar to reopen the window, view history, sync now, or quit. The installed sync schedule continues after quitting the app.
- Enable Launch at login in Settings → General to register a macOS login item. This is separate from the scheduled sync task.
- Choose notifications for conflicts or failures, every completed run, or off. Notifications are off by default; enabling them requests macOS permission. Notification text contains no file names or paths.
- Use the prominent Sync now button for all enabled folders or the selected pair; explicit merge, upload, and download actions remain available.
- Read past runs in the History page, with time, folder, direction, counts, and expandable conflict or failure details. Open or reveal affected files and pre-overwrite backups in Finder. For LaTeX text, compare a saved pre-overwrite version with its current file, or compare current sides and conflict copies, using an offline diff and line/section summary. You can explicitly ask the installed Codex CLI to summarize the selected diff. Filter by folder or result; the raw log remains available for troubleshooting.
- By default, divergent files keep both versions automatically. Both originals are backed up locally before either synced folder changes. The sync then completes with no confirmation needed; History lists the conflict copy, and notifications follow your setting. You can choose to pause for a manual decision instead.
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

[Download the Apple Silicon app](https://github.com/ensomnia16/PathSync/releases/tag/v2.16.4) for macOS 13 or later. The app is not notarized by Apple.

To build locally, install Xcode Command Line Tools and run `./build.sh`. Copy the resulting `.build/路径同步.app` into `/Applications`, select folders, and save settings. The saved schedule runs through a per-user macOS LaunchAgent while you are signed in.

The interface uses native SwiftUI sidebar, form, and toolbar controls. Overview shows overall status, the last sync, the schedule interval or next fixed time, and a card per folder pair; each folder page edits its paths, direction, and conflicts; Settings groups schedule, conflicts and backups, filtering, notifications, and language. Unsaved changes are shown in the status bar. The icon is a white two-drawer cabinet with blue fronts and clear white handles. Its source image is `PathSyncIcon.png`.

The [synchronization model](docs/synchronization-model.md) records the primary sources, state transitions, and current limits around directory conflicts and OneDrive availability.

For an already preserved conflict, “Use newer current version” compares the current main file and preserved copy. The preserved copy must match across both folders. If the main files differ, the action can first back up and propagate a change made on just one side relative to the anchor. Changes on both sides still pause. Inspect the newer file before using the date-based action.

Starting with 2.11.0, there is no separate deletion-propagation switch. The old `propagateDeletions` configuration field is ignored when loading and removed on the next save. Use `--dry-run` to preview actions on existing folders after upgrading.

In two-way merge and upload, the local version remains at the original path while a labeled cloud copy appears in both folders. In download, the cloud version remains at the original path and a labeled local copy appears in both folders. Backups are stored under `~/Library/Application Support/ResearchSync/merge-state/`. Keeping both preserves content but does not merge it into the original file; merge the two versions yourself when needed. Automatic keep-both leaves nothing pending, and reviews left by older versions are cleared on the next automatic sync. With “Pause for a decision”, choosing Keep both by hand marks the item for review until you acknowledge it; the copy and backup remain. Manual conflicts stay pending until resolved; if either original changes after listing, sync again before choosing a version.

History reads the existing `sync.log`, so older runs remain visible. It shows records for currently configured folder pairs, loading up to the last 2 MB of the log and displaying the newest 200 runs. Ordinary transfers show counts; conflicts and failures include filenames.

## Shortcuts

Use the “Open URL” action in Shortcuts:

```text
pathsync://sync                 sync all enabled folders in their own directions
pathsync://sync?pair=ID-or-name sync one folder pair (its ID or a unique name)
pathsync://open                 open the main window
```

A sync request is ignored while settings are unsaved or another sync is running. For status, use “Run Shell Script” with `/Applications/路径同步.app/Contents/MacOS/PathSync --status`. It prints each pair's last sync, result, and pending conflicts, plus whether a sync is running, as JSON, and only reads.

`build.sh` builds with the Command Line Tools and cannot produce App Intents metadata, so native Shortcuts actions are not available in this build; adding them needs an Xcode project.

The white two-drawer cabinet icon master is `PathSyncIcon.png`. The existing `.icns` build wraps it using `tools/package-legacy-icon.swift`; artwork provenance is recorded in `app-icon/provenance.json`.

The menu bar drawer icon has three states: slash (scheduled sync off), rotating arrows (sync in progress), and check (enabled). A read-only sync-lock check runs about every two seconds, including for the external scheduled worker. Unsaved settings do not change the reported schedule state. The cabinet artwork is 10% smaller inside the existing white icon tile.

The executable is named `PathSync`; a `ResearchSync` symlink preserves existing CLI scripts. The bundle identifier and data directory stay unchanged. LaunchAgents declare `AssociatedBundleIdentifiers`, and an existing schedule is migrated without changing its interval. Update backups are kept outside Applications as non-app folders to avoid duplicate app/notification registrations.
