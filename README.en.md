# PathSync

A small macOS app for syncing local working folders with mounted cloud folders on a schedule. It is useful when local builds, such as LaTeX, create many short-lived files.

## Features

- Manage multiple folder pairs. Each pair has its own sync direction: two-way merge, local to cloud, or cloud to local.
- Set a shared default schedule: any daily time or an interval from 6 to 168 hours.
- Run a pair manually in either direction. All directions share one change baseline and pause a file when its destination has diverged.
- Review pending conflicts in the app and choose the local version, the cloud version, or both. Both originals are backed up locally before a decision changes either synced folder.
- The app refreshes pending conflicts when brought forward and while open; you can refresh them manually as well.
- Sync never propagates deletions. LaTeX build files, virtual environments, and common caches can be excluded.
- Switch the interface between Simplified Chinese, English, and the system language.

## Download and build

[Download the Apple Silicon app](https://github.com/ensomnia16/PathSync/releases/tag/v2.5.1) for macOS 13 or later. The app is not notarized by Apple.

To build locally, install Xcode Command Line Tools and run `./build.sh`. Copy the resulting `.build/路径同步.app` into `/Applications`, select folders, and save settings. The saved schedule runs through a per-user macOS LaunchAgent while you are signed in.

The interface uses native SwiftUI sidebar, form, and toolbar controls. The selected blue icon uses a single-axis, two-way arrow. Its generated source image is `PathSyncIcon.png`.

Conflicts stay pending until resolved. “Keep both” retains the local file at the original path and creates a labeled copy of the cloud version in both folders. Backups are stored under `~/Library/Application Support/ResearchSync/merge-state/`. If either original changes after the conflict was listed, sync again before choosing a version.
