import Foundation

enum OneDriveConnection {
    static var helper: URL { Bundle.main.resourceURL!.appendingPathComponent("OneDriveAuth") }
    private static func status(_ command: String) -> Int32 {
        let process = Process(); process.executableURL = helper; process.arguments = [command]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }
    static func perform(_ command: String) -> Bool { status(command) == 0 }
    static var isConnected: Bool { perform("--status") }
    // Only a confirmed missing item permits the unconnected sync path.
    static var shouldUseCloudIndex: Bool { status("--status") != 10 }
}
