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
    let signature = try key.signature(for: Data(contentsOf: archiveURL))
    let signatureURL = URL(fileURLWithPath: archiveURL.path + ".sig")
    try signature.base64EncodedString().write(to: signatureURL, atomically: true, encoding: .utf8)
    print(signatureURL.path)
default:
    fatalError("unknown command")
}
