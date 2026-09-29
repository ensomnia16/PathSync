import Foundation
import CryptoKit

struct CloudImportAnchor: Codable, Equatable {
    let revisionID: UUID
    let sharedDigest: String
    let localDigest: String?
}

func localSharedDigest(_ config: SyncConfig, pairIDs: Set<UUID>) -> String {
    var shared = config
    shared.pairs = config.pairs.filter { pairIDs.contains($0.id) }
    return CloudConfiguration(config: shared, deviceID: UUID(), deviceName: "local").sharedDigest
}

// Each Mac writes a separate iCloud Drive document; paths and active state stay local.
struct CloudConfigPair: Codable, Equatable {
    let id: UUID
    let name: String
    let scheduledDirection: String
    let oneDriveRelativePath: String?
    let localRelativePath: String?
    var isUnusedDefaultPlaceholder: Bool {
        name == "新路径" && scheduledDirection == "merge" &&
            oneDriveRelativePath == nil && localRelativePath == nil
    }
}

struct CloudConfiguration: Codable, Equatable, Identifiable {
    let schemaVersion: Int
    let deviceID: UUID
    let deviceName: String
    let revisionID: UUID
    let modifiedAt: Date
    let pairs: [CloudConfigPair]
    let scheduleMode: String
    let intervalHours: Int
    let dailyHour: Int
    let dailyMinute: Int
    let excludeLatexIntermediates: Bool
    let conflictPolicy: String
    let backupRetentionDays: Int
    let importedRevisions: [String: UUID]?
    var id: UUID { deviceID }
    var effectivePairs: [CloudConfigPair] { pairs.filter { !$0.isUnusedDefaultPlaceholder } }

    var sharedDigest: String {
        let entries = effectivePairs.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            [$0.id.uuidString, $0.name, $0.scheduledDirection,
             $0.oneDriveRelativePath ?? "", $0.localRelativePath ?? ""]
        }
        let value: [String: Any] = [
            "pairs": entries, "scheduleMode": scheduleMode, "intervalHours": intervalHours,
            "dailyHour": dailyHour, "dailyMinute": dailyMinute,
            "excludeLatexIntermediates": excludeLatexIntermediates,
            "conflictPolicy": conflictPolicy, "backupRetentionDays": backupRetentionDays
        ]
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(config: SyncConfig, deviceID: UUID, deviceName: String) {
        schemaVersion = 1
        self.deviceID = deviceID
        self.deviceName = deviceName
        revisionID = UUID()
        modifiedAt = Date()
        pairs = config.pairs.filter { !$0.isUnusedDefaultPlaceholder }.map { pair in
            CloudConfigPair(id: pair.id, name: pair.name,
                            scheduledDirection: pair.scheduledDirection,
                            oneDriveRelativePath: relativePath(pair.cloudPath, within: config.oneDriveRoot),
                            localRelativePath: relativePath(pair.localPath, within: config.localRoot))
        }
        scheduleMode = config.scheduleMode
        intervalHours = config.intervalHours
        dailyHour = config.dailyHour
        dailyMinute = config.dailyMinute
        excludeLatexIntermediates = config.excludeLatexIntermediates
        conflictPolicy = config.conflictPolicy
        backupRetentionDays = config.backupRetentionDays
        importedRevisions = config.cloudImportAnchors.mapValues(\.revisionID)
    }

    func validate() throws {
        guard schemaVersion == 1, !deviceName.isEmpty, deviceName.utf8.count <= 200,
              pairs.count <= 200, Set(pairs.map(\.id)).count == pairs.count,
              ["daily", "interval"].contains(scheduleMode), (6...168).contains(intervalHours),
              (0...23).contains(dailyHour), (0...59).contains(dailyMinute),
              ["keep-both", "ask", "newest"].contains(conflictPolicy),
              (1...365).contains(backupRetentionDays),
              (importedRevisions?.count ?? 0) <= 250,
              (importedRevisions ?? [:]).keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              pairs.allSatisfy({ pair in
                  !pair.name.isEmpty && pair.name.utf8.count <= 500 &&
                  ["merge", "upload", "download"].contains(pair.scheduledDirection) &&
                  (pair.oneDriveRelativePath == nil || isSafeRelativePath(pair.oneDriveRelativePath!)) &&
                  (pair.localRelativePath == nil || isSafeRelativePath(pair.localRelativePath!))
              }) else { throw CloudConfigError.invalid }
    }
}

func isSafeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 4_096 && !value.hasPrefix("/") &&
    !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
    }) && !value.contains("\0")
}

func relativePath(_ value: String, within root: String) -> String? {
    guard !value.isEmpty, !root.isEmpty else { return nil }
    let base = URL(fileURLWithPath: root).standardizedFileURL.path
    let full = URL(fileURLWithPath: value).standardizedFileURL.path
    guard full.hasPrefix(base + "/") else { return nil }
    let relative = String(full.dropFirst(base.count + 1))
    return isSafeRelativePath(relative) ? relative : nil
}

func path(in root: String, relative: String) -> String? {
    guard !root.isEmpty, isSafeRelativePath(relative) else { return nil }
    let base = URL(fileURLWithPath: root).standardizedFileURL
    let full = base.appendingPathComponent(relative).standardizedFileURL.path
    return full.hasPrefix(base.path + "/") ? full : nil
}

// Remote removal never silently removes a local pair. New or rebound pairs must be enabled locally.
func importing(_ profile: CloudConfiguration, into current: SyncConfig) throws -> SyncConfig {
    try profile.validate()
    var result = current
    let old = Dictionary(uniqueKeysWithValues: current.pairs
        .filter { !$0.isUnusedDefaultPlaceholder }.map { ($0.id, $0) })
    result.pairs = profile.effectivePairs.map { shared in
        var pair = old[shared.id] ?? SyncPair(id: shared.id)
        if old[shared.id]?.scheduledDirection != nil &&
            old[shared.id]?.scheduledDirection != shared.scheduledDirection { pair.enabled = false }
        pair.name = shared.name
        pair.scheduledDirection = shared.scheduledDirection
        if let relative = shared.oneDriveRelativePath,
           let cloud = path(in: current.oneDriveRoot, relative: relative) {
            if !pair.cloudPath.isEmpty && pair.cloudPath != cloud { pair.enabled = false }
            pair.cloudPath = cloud
        }
        if pair.localPath.isEmpty, let relative = shared.localRelativePath,
           let local = path(in: current.localRoot, relative: relative) {
            pair.localPath = local
        }
        if old[shared.id] == nil { pair.enabled = false }
        return pair
    }
    result.pairs += current.pairs.filter { pair in
        !pair.isUnusedDefaultPlaceholder && !profile.effectivePairs.contains(where: { $0.id == pair.id })
    }
    result.scheduleMode = profile.scheduleMode
    result.intervalHours = profile.intervalHours
    result.dailyHour = profile.dailyHour
    result.dailyMinute = profile.dailyMinute
    result.excludeLatexIntermediates = profile.excludeLatexIntermediates
    result.conflictPolicy = profile.conflictPolicy
    result.backupRetentionDays = profile.backupRetentionDays
    if !result.pairs.contains(where: \.enabled) { result.enabled = false }
    result.cloudImportAnchors[profile.deviceID.uuidString.lowercased()] =
        CloudImportAnchor(revisionID: profile.revisionID, sharedDigest: profile.sharedDigest,
            localDigest: localSharedDigest(result, pairIDs: Set(profile.effectivePairs.map(\.id))))
    return result
}

struct CloudImportPreview: Identifiable {
    let profile: CloudConfiguration
    let current: SyncConfig
    let proposed: SyncConfig
    let changed: [SyncPair]
    let preservedLocalPairs: [SyncPair]
    let localEditsConflict: Bool
    let bothChanged: Bool
    let ruleChanges: [String]
    let missingFolders: [String]
    var id: UUID { profile.revisionID }

    init(profile: CloudConfiguration, current: SyncConfig) throws {
        self.profile = profile
        self.current = current
        proposed = try importing(profile, into: current)
        changed = proposed.pairs.filter { pair in
            current.pairs.first(where: { $0.id == pair.id }) != pair
        }
        let remoteIDs = Set(profile.effectivePairs.map(\.id))
        preservedLocalPairs = current.pairs.filter {
            !$0.isUnusedDefaultPlaceholder && !remoteIDs.contains($0.id)
        }
        let anchor = current.cloudImportAnchors[profile.deviceID.uuidString.lowercased()]
        let currentDigest = localSharedDigest(current, pairIDs: Set(profile.effectivePairs.map(\.id)))
        localEditsConflict = anchor?.localDigest != nil && anchor?.localDigest != currentDigest
        bothChanged = localEditsConflict && anchor?.sharedDigest != profile.sharedDigest
        var changes: [String] = []
        if current.scheduleMode != proposed.scheduleMode || current.intervalHours != proposed.intervalHours ||
            current.dailyHour != proposed.dailyHour || current.dailyMinute != proposed.dailyMinute {
            changes.append("schedule")
        }
        if current.conflictPolicy != proposed.conflictPolicy { changes.append("conflict") }
        if current.backupRetentionDays != proposed.backupRetentionDays { changes.append("backup") }
        if current.excludeLatexIntermediates != proposed.excludeLatexIntermediates { changes.append("latex") }
        ruleChanges = changes
        missingFolders = proposed.pairs.filter { pair in
            !pair.localPath.isEmpty && !FileManager.default.fileExists(atPath: pair.localPath)
        }.map { $0.name + ": " + $0.localPath }
    }
}

enum CloudConfigError: LocalizedError {
    case unavailable, invalid, tooLarge, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: return "iCloud Drive 不可用。请在系统设置中开启 iCloud Drive。"
        case .invalid: return "iCloud 中的配置格式或路径无效。"
        case .tooLarge: return "配置超过 1 MB，已停止读取。"
        case .conflict: return "iCloud 配置文件存在多个版本，请先在 Finder 中检查。"
        }
    }
}

func cloudConfigErrorText(_ error: Error, language: String) -> String {
    guard usesEnglish(language), let cloudError = error as? CloudConfigError else {
        return error.localizedDescription
    }
    switch cloudError {
    case .unavailable: return "iCloud Drive is unavailable. Enable it in System Settings."
    case .invalid: return "The iCloud configuration contains invalid data or paths."
    case .tooLarge: return "The configuration exceeds 1 MB and was not read."
    case .conflict: return "The iCloud configuration has multiple versions. Review it in Finder."
    }
}

struct CloudConfigStore {
    let root: URL
    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var iCloudRoot: URL {
        iCloudDrive.appendingPathComponent("PathSync/Configuration", isDirectory: true)
    }

    func transferStatus(for deviceID: UUID) -> String {
        let url = root.appendingPathComponent(deviceID.uuidString.lowercased() + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey]) else { return "unknown" }
        if values.ubiquitousItemUploadingError != nil { return "error" }
        if values.ubiquitousItemIsUploading == true { return "uploading" }
        if values.ubiquitousItemIsUploaded == true { return "uploaded" }
        return values.isUbiquitousItem == true ? "pending" : "unknown"
    }

    func write(_ profile: CloudConfiguration) throws {
        try profile.validate()
        let fm = FileManager.default
        if root == Self.iCloudRoot && !fm.fileExists(atPath: Self.iCloudDrive.path) {
            throw CloudConfigError.unavailable
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        guard data.count <= 1_000_000 else { throw CloudConfigError.tooLarge }
        let url = root.appendingPathComponent(profile.deviceID.uuidString.lowercased() + ".json")
        if fm.fileExists(atPath: url.path),
           !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty {
            throw CloudConfigError.conflict
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    func readOthers(excluding ownID: UUID) throws -> [CloudConfiguration] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            if root == Self.iCloudRoot && !fm.fileExists(atPath: Self.iCloudDrive.path) {
                throw CloudConfigError.unavailable
            }
            return []
        }
        let files = try fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
        guard files.count <= 250 else { throw CloudConfigError.invalid }
        var profiles: [CloudConfiguration] = []
        for url in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), id != ownID else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_000_000 else {
                throw CloudConfigError.tooLarge
            }
            guard (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty else {
                throw CloudConfigError.conflict
            }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var operationError: Error?
            var data: Data?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                do { data = try Data(contentsOf: coordinatedURL) }
                catch { operationError = error }
            }
            if let coordinationError { throw coordinationError }
            if let operationError { throw operationError }
            guard let data, data.count <= 1_000_000,
                  let profile = try? JSONDecoder().decode(CloudConfiguration.self, from: data),
                  profile.deviceID == id else { throw CloudConfigError.invalid }
            try profile.validate()
            profiles.append(profile)
        }
        return profiles.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
