import Foundation

enum OneDriveConnection {
    static var helper: URL { Bundle.main.resourceURL!.appendingPathComponent("OneDriveAuth") }
    static func perform(_ command: String) -> Bool {
        let process = Process(); process.executableURL = helper; process.arguments = [command]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
    static var isConnected: Bool { perform("--status") }
}
