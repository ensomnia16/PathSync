import Foundation

@main
struct UpdateInstallChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("archive and signature paths required") }
        let archive = URL(fileURLWithPath: CommandLine.arguments[1])
        let signature = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try verifyUpdateArchive(archive, signatureText: signature)
        assert((try? verifyUpdateArchive(archive, signatureText: Data("bad".utf8))) == nil)
        let contents = try Data(contentsOf: archive)
        let altered = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: altered) }
        var bytes = contents
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: altered)
        assert((try? verifyUpdateArchive(altered, signatureText: signature)) == nil)
        print("update signature checks passed")
    }
}
