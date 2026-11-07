import Foundation

@main
struct CodeSigningChecks {
    static func main() throws {
        precondition(CommandLine.arguments.count == 3)
        for (path, expected) in [(CommandLine.arguments[1], Int32(0)),
                                 (CommandLine.arguments[2], Int32(3))] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--deep", "--strict", "-R",
                                 pathSyncCodeSigningRequirement(), path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if expected == 0 {
                precondition(process.terminationStatus == 0, "Pinned identity must be accepted")
            } else {
                precondition(process.terminationStatus != 0, "Ad-hoc identity must be rejected")
            }
        }
        print("Pinned identity accepted; ad-hoc identity rejected")
    }
}
