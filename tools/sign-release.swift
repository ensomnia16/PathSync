import CryptoKit
import Foundation
import Darwin

let keyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/pathsync-release-signing/ed25519.key")

guard CommandLine.arguments.count >= 2 else {
    fatalError("usage: sign-release generate | sign ARCHIVE")
}
switch CommandLine.arguments[1] {
case "generate":
    guard !FileManager.default.fileExists(atPath: keyURL.path) else {
        fatalError("release signing key already exists")
    }
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: keyURL, options: [.atomic])
    guard chmod(keyURL.path, 0o600) == 0 else { fatalError("could not protect signing key") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard CommandLine.arguments.count == 3 else { fatalError("sign requires an archive path") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("pathsync-sign-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    for (tool, arguments) in [
        ("/usr/bin/ditto", ["-x", "-k", archiveURL.path, staging.path]),
        ("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R",
            "=identifier \"com.ensom.ResearchSync\" and certificate leaf = H\"C47BF244BCBD892D97951161EB00ABCA90E81918\"",
            staging.appendingPathComponent("路径同步.app").path])
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PathSyncSigning", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Archive must contain the persistent PathSync application signature."])
        }
    }
    let signature = try key.signature(for: Data(contentsOf: archiveURL))
    let signatureURL = URL(fileURLWithPath: archiveURL.path + ".sig")
    try signature.base64EncodedString().write(to: signatureURL, atomically: true, encoding: .utf8)
    print(signatureURL.path)
default:
    fatalError("unknown command")
}
