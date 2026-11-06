import AppKit
import CoreServices

/// Old updaters kept an application bundle beside the installed app. That
/// duplicate could remain registered for the same notification identity.
func refreshApplicationIdentity() {
    let current = Bundle.main.bundleURL
    guard current.pathExtension == "app", let identifier = Bundle.main.bundleIdentifier else { return }
    let legacy = current.deletingLastPathComponent().appendingPathComponent(".路径同步.previous.app")
    let fm = FileManager.default
    if legacy != current, Bundle(url: legacy)?.bundleIdentifier == identifier,
       !syncIsRunning(),
       !NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .contains(where: { $0.bundleURL?.standardizedFileURL == legacy.standardizedFileURL }) {
        let backups = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ResearchSync/update-backups", isDirectory: true)
        do {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let unregister = Process()
            unregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
            unregister.arguments = ["-u", legacy.path]
            unregister.standardOutput = FileHandle.nullDevice
            unregister.standardError = FileHandle.nullDevice
            try unregister.run()
            unregister.waitUntilExit()
            try fm.moveItem(at: legacy, to: backups.appendingPathComponent("legacy-" + UUID().uuidString + ".bundle-backup"))
        } catch {
            // Preserve the backup on failure and keep the current app usable.
            NSLog("PathSync: legacy application backup could not be archived: %@", error.localizedDescription)
        }
    }
    LSRegisterURL(current as CFURL, true)
}
