import Darwin
import Foundation
import Security

// The original helper's CDHash is part of the login keychain partition ACL.
// Check access metadata without prompting before invoking that exact binary.
let trustedHelpers = [
    (name: "OneDriveAuth", hash: "dfca18ab2bfa4da69164e32b3aa8b3e9f928dbb9"),
    (name: "OneDriveAuth-2.19.3", hash: "0b2088de41f178f74a0bf38164c8e8ef2bfe2969"),
]
let service = "com.ensom.PathSync.OneDrive.ReadOnly.v1"

func check(_ status: OSStatus) {
    switch status {
    case errSecSuccess: return
    case errSecItemNotFound: exit(10)
    case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled: exit(11)
    default: exit(12)
    }
}

func unlocked(_ keychain: SecKeychain) {
    var status: SecKeychainStatus = 0
    check(SecKeychainGetStatus(keychain, &status))
    guard status & UInt32(kSecUnlockStateStatus) != 0 else { exit(11) }
}

func partitionList(_ description: String) -> [String]? {
    let hex = Array(description.utf8)
    guard !hex.isEmpty, hex.count.isMultiple(of: 2), hex.count < 65536 else { return nil }
    var data = Data()
    for index in stride(from: 0, to: hex.count, by: 2) {
        let pair = String(decoding: hex[index...index + 1], as: UTF8.self)
        guard let byte = UInt8(pair, radix: 16) else { return nil }
        data.append(byte)
    }
    guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = value as? [String: Any] else { return nil }
    return dictionary["Partitions"] as? [String]
}

func authorizedPartitions(_ item: SecKeychainItem, resources: URL) -> [String] {
    var keychain: SecKeychain?
    check(SecKeychainItemCopyKeychain(item, &keychain))
    guard let keychain else { exit(12) }
    unlocked(keychain)

    var access: SecAccess?
    check(SecKeychainItemCopyAccess(item, &access))
    guard let access else { exit(12) }
    var list: CFArray?
    check(SecAccessCopyACLList(access, &list))
    guard let entries = list as? [SecACL] else { exit(12) }
    var trusted = false
    var partitions: [String] = []
    for entry in entries {
        let tags = SecACLCopyAuthorizations(entry) as? [String] ?? []
        guard tags.contains("ACLAuthorizationDecrypt") || tags.contains("ACLAuthorizationPartitionID") else { continue }
        var apps: CFArray?, description: CFString?
        var prompt = SecKeychainPromptSelector()
        check(SecACLCopyContents(entry, &apps, &description, &prompt))
        if tags.contains("ACLAuthorizationPartitionID"), let description = description as String? {
            partitions.append(contentsOf: partitionList(description) ?? [])
        }
        if tags.contains("ACLAuthorizationDecrypt"), prompt.rawValue == 0,
           let applications = apps as? [SecTrustedApplication] {
            trusted = trusted || applications.contains { application in
                var data: CFData?
                guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess,
                      let bytes = data as Data?, let path = String(data: bytes, encoding: .utf8) else { return false }
                let approvedPath = path.trimmingCharacters(in: .controlCharacters)
                return trustedHelpers.contains { resources.appendingPathComponent($0.name).path == approvedPath }
            }
        }
    }
    guard trusted else { exit(14) }
    return partitions
}

check(SecKeychainSetUserInteractionAllowed(false))
let command = CommandLine.arguments.dropFirst().first ?? "--status"
guard ["--status", "--check-access", "--token", "--connect", "--disconnect"].contains(command) else { exit(2) }
let resources = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()

let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: "rclone",
    kSecReturnRef as String: true,
]
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
let selected: (name: String, hash: String)
if status == errSecItemNotFound, command == "--disconnect" { exit(0) }
if status == errSecItemNotFound, command == "--connect" {
    var keychain: SecKeychain?
    check(SecKeychainCopyDefault(&keychain))
    guard let keychain else { exit(12) }
    unlocked(keychain)
    selected = trustedHelpers[0]
} else {
    check(status)
    guard let result, CFGetTypeID(result) == SecKeychainItemGetTypeID() else { exit(12) }
    let partitions = authorizedPartitions(result as! SecKeychainItem, resources: resources)
    guard let match = trustedHelpers.first(where: { partitions.contains("cdhash:" + $0.hash) }) else { exit(14) }
    selected = match
}
let helper = resources.appendingPathComponent(selected.name)
var code: SecStaticCode?
check(SecStaticCodeCreateWithPath(helper as CFURL, [], &code))
var requirement: SecRequirement?
check(SecRequirementCreateWithString(("cdhash H\"" + selected.hash + "\"") as CFString, [], &requirement))
guard let code, let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { exit(12) }
if command == "--status" || command == "--check-access" { exit(0) }

let arguments = [helper.path, command].map { strdup($0) } + [nil]
execv(helper.path, arguments)
exit(12)
