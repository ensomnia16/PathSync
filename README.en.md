# PathSync

A small macOS app for syncing local working folders with mounted cloud folders on a schedule. It is useful when local builds, such as LaTeX, create many short-lived files.

## Features

- Manage multiple folder pairs. Each pair has its own sync direction: two-way merge, local to cloud, or cloud to local.
- Set a shared default schedule: any daily time or an interval from 6 to 168 hours.
- Run a pair manually in either direction. The merge mode copies one-sided changes and reports conflicting edits while preserving both originals.
- Sync never propagates deletions. LaTeX build files, virtual environments, and common caches can be excluded.
- Switch the interface between Simplified Chinese, English, and the system language.

## Download and build

[Download the Apple Silicon app](https://github.com/ensomnia16/PathSync/releases/tag/v2.4.0) for macOS 13 or later. The app is not notarized by Apple.

To build locally, install Xcode Command Line Tools and run `./build.sh`. Copy the resulting `.build/路径同步.app` into `/Applications`, select folders, and save settings. The saved schedule runs through a per-user macOS LaunchAgent while you are signed in.

The interface uses native SwiftUI sidebar, form, and toolbar controls. The blue icon uses two opposing arrows to represent two-way sync. Recreate it with `swift GenerateIcon.swift PathSyncIcon.png`.
