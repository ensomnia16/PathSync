import AppKit
import Foundation

@main
struct MenuBarStateChecks {
    static func main() throws {
        for schedule in [false, true] {
            for pairs in [false, true] {
                assert(SyncMenuBarState.resolve(scheduleEnabled: schedule, hasEnabledPairs: pairs,
                                                uiBusy: true, workerRunning: false) == .syncing)
                assert(SyncMenuBarState.resolve(scheduleEnabled: schedule, hasEnabledPairs: pairs,
                                                uiBusy: false, workerRunning: true) == .syncing)
                let idle = SyncMenuBarState.resolve(scheduleEnabled: schedule, hasEnabledPairs: pairs,
                                                    uiBusy: false, workerRunning: false)
                assert(idle == (schedule && pairs ? .enabled : .disabled))
            }
        }
        var config = SyncConfig()
        config.scheduleMode = "interval"
        config.intervalHours = 12
        let binary = "/Applications/PathSync.app/Contents/MacOS/PathSync"
        let scheduled = schedulePropertyList(config, binary: binary)
        assert(scheduled["AssociatedBundleIdentifiers"] as? [String] == ["com.ensom.ResearchSync"])
        assert(scheduled["StartInterval"] as? Int == 43200)
        assert(scheduled["ProgramArguments"] as? [String] == [binary, "--sync"])
        assert(!scheduleNeedsIdentityMigration(scheduled, binary: binary))
        assert(scheduleNeedsIdentityMigration(["ProgramArguments": ["/old/ResearchSync", "--sync"]], binary: binary))
        config.scheduleMode = "daily"
        config.dailyHour = 7
        config.dailyMinute = 25
        assert(schedulePropertyList(config, binary: binary)["StartCalendarInterval"] as? [String: Int] == ["Hour": 7, "Minute": 25])
        config.pairs = [SyncPair(name: "Test", localPath: "/preview/local", cloudPath: "/preview/cloud", enabled: true)]
        let model = SyncModel(testConfig: config)
        assert(model.menuBarState == .enabled)
        model.config.enabled = false
        assert(model.hasUnsavedChanges)
        assert(model.menuBarState == .enabled, "an unsaved draft must not claim the installed schedule is off")
        for state in SyncMenuBarState.allCases {
            assert(menuBarIcon(for: state).isTemplate)
            assert(menuBarIcon(for: state).size == NSSize(width: 22, height: 18))
        }
        assert(menuBarIcon(for: .syncing, phase: 0).tiffRepresentation !=
               menuBarIcon(for: .syncing, phase: 1).tiffRepresentation,
               "the syncing badge must have distinct animation frames")

        // Exercise a real lock held by a separate worker, without touching the
        // user's sync lock or launching a file synchronization.
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("worker.lock").path
        assert(!syncIsRunning(at: path))
        let worker = Process()
        let ready = Pipe()
        let release = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        worker.arguments = ["-c", "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('READY',flush=True); sys.stdin.read()", path]
        worker.standardOutput = ready
        worker.standardInput = release
        try worker.run()
        assert(ready.fileHandleForReading.readData(ofLength: 6) == Data("READY\n".utf8))
        assert(syncIsRunning(at: path))
        assert(SyncMenuBarState.resolve(scheduleEnabled: true, hasEnabledPairs: true,
                                       uiBusy: false, workerRunning: syncIsRunning(at: path)) == .syncing)
        try release.fileHandleForWriting.close()
        worker.waitUntilExit()
        assert(worker.terminationStatus == 0)
        assert(!syncIsRunning(at: path))
        print("Three icon states, saved settings, native template sizes and external-worker lock checks passed.")
    }
}
