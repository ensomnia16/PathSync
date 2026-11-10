import Foundation
import Security
import LocalAuthentication
import Darwin
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A separately signed helper owns the Keychain entry for GUI and launchd alike.
let service = "com.ensom.PathSync.OneDrive.ReadOnly.v1"
let account = "rclone"
func query() -> [String: Any] {
    let context = LAContext(); context.interactionNotAllowed = true
    return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context]
}
enum AuthFailure: Int32 {
    case invalid = 2
    case missing = 10
    case keychainInteraction = 11
    case keychainFailure = 12
    case refresh = 13
}

func fail(_ reason: AuthFailure = .invalid) -> Never {
    // The caller translates these codes. Do not print token or provider data.
    exit(reason.rawValue)
}

func checkKeychain(_ status: OSStatus) {
    switch status {
    case errSecSuccess: return
    case errSecItemNotFound: fail(.missing)
    case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
        fail(.keychainInteraction)
    default: fail(.keychainFailure)
    }
}
func read() -> Data {
    var q = query(); q[kSecReturnData as String] = true
    var result: CFTypeRef?
    checkKeychain(SecItemCopyMatching(q as CFDictionary, &result))
    guard let data = result as? Data else { fail() }
    return data
}
func save(_ data: Data) {
    let attributes = [kSecValueData as String: data]
    let code = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
    if code == errSecItemNotFound {
        var q = query(); q.removeValue(forKey: kSecUseAuthenticationContext as String)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        checkKeychain(SecItemAdd(q as CFDictionary, nil))
    } else { checkKeychain(code) }
}
func object(_ data: Data) -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { fail() }
    return value
}
func json(_ value: [String: Any]) -> Data {
    guard let result = try? JSONSerialization.data(withJSONObject: value) else { fail() }; return result
}
func run(_ args: [String], input: Data? = nil) -> Data {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("OneDriveOAuth")
    task.arguments = args
    let output = Pipe(); task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    if let input {
        let pipe = Pipe(); task.standardInput = pipe
        do { try task.run(); try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close() } catch { fail() }
    } else { task.standardInput = FileHandle.nullDevice; do { try task.run() } catch { fail() } }
    let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { fail(args.first == "refresh-memory" ? .refresh : .invalid) }
    return data
}
func decodeBlob(_ value: String) -> Data? {
    Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
}
func driveID(_ token: String) -> String {
    var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive?$select=id,driveType")!)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 25
    let semaphore = DispatchSemaphore(value: 0)
    var drive: String?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        defer { semaphore.signal() }
        if let data, (response as? HTTPURLResponse)?.statusCode == 200,
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           value["driveType"] as? String == "personal" { drive = value["id"] as? String }
    }.resume()
    _ = semaphore.wait(timeout: .now() + 30)
    guard let drive else { fail() }; return drive
}
let command = CommandLine.arguments.dropFirst().first ?? "--status"
// The existing item is in the file-based login keychain. LAContext alone
// does not suppress its SecurityAgent prompts. Keep the ACL enforced.
checkKeychain(SecKeychainSetUserInteractionAllowed(false))
switch command {
case "--status":
    var q = query(); q[kSecReturnAttributes as String] = true
    checkKeychain(SecItemCopyMatching(q as CFDictionary, nil))
case "--disconnect":
    let result = SecItemDelete(query() as CFDictionary)
    if result != errSecItemNotFound { checkKeychain(result) }
case "--connect":
    // Genuine rclone authorize. A browser opens only for this explicit command.
    let blob = json(["access_scopes": "Files.Read offline_access"]).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let output = run(["authorize", "onedrive", blob, "--config", "/dev/null"])
    guard let text = String(data: output, encoding: .utf8),
          let start = text.range(of: "--->\n"), let end = text.range(of: "\n<---End paste", range: start.upperBound..<text.endIndex),
          let decoded = decodeBlob(String(text[start.upperBound..<end.lowerBound])) else { fail() }
    let result = object(decoded)
    guard let tokenJSON = result["token"] as? String, let data = tokenJSON.data(using: .utf8) else { fail() }
    let token = object(data)
    guard let access = token["access_token"] as? String, token["refresh_token"] as? String != nil else { fail() }
    save(json(["token": token, "drive_id": driveID(access)]))
case "--check-access":
    _ = read()
case "--token":
    // Concurrent pairs share one rotating refresh token; refresh sequentially.
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PathSync/Auth", isDirectory: true)
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { fail() }
    let lock = open(folder.appendingPathComponent("refresh.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX) == 0 else { fail() }
    defer { flock(lock, LOCK_UN); close(lock) }
    var value = object(read())
    guard let token = value["token"] as? [String: Any], let expiry = token["expiry"] as? String else { fail() }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: expiry) ?? ISO8601DateFormatter().date(from: expiry) ?? .distantPast
    if date.timeIntervalSinceNow < 180 {
        value = object(run(["refresh-memory"], input: json(value)))
        save(json(value))
    }
    guard let refreshed = value["token"] as? [String: Any], let access = refreshed["access_token"] as? String,
          let drive = value["drive_id"] as? String else { fail() }
    FileHandle.standardOutput.write(json(["access_token": access, "drive_id": drive]))
default: fail()
}
