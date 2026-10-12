import AppKit
import Foundation
import SwiftUI
import ServiceManagement
import UserNotifications

private let appID = "com.ensom.ResearchSync"
private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser.path
private let supportDirectory = home + "/Library/Application Support/ResearchSync"
private let defaultConfigPath = supportDirectory + "/config.json"
let logPath = supportDirectory + "/sync.log"
private let agentPath = home + "/Library/LaunchAgents/" + appID + ".plist"

private func mergeStatePath(_ pair: SyncPair) -> String {
    supportDirectory + "/merge-state/" + pair.id.uuidString.lowercased() + ".json"
}

func localBackupFolders(_ pair: SyncPair) -> [String] {
    let stem = URL(fileURLWithPath: mergeStatePath(pair)).deletingPathExtension().path
    return [stem + "-backups", stem + "-conflict-backups"]
}

/// A saved backup lives in the chosen backup folder, or beside the merge state
/// while that folder was unavailable.
private func backupDirectory(_ pair: SyncPair, id: String, config: SyncConfig) -> String? {
    guard id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
    var candidates = [localBackupFolders(pair)[0] + "/" + id]
    if let remote = config.remoteBackupDirectory(pair) { candidates.insert(remote + "/backups/" + id, at: 0) }
    return candidates.first { fm.fileExists(atPath: $0 + "/manifest.json") }
}

func backupAvailable(_ pair: SyncPair, id: String, config: SyncConfig) -> Bool {
    guard let root = backupDirectory(pair, id: id, config: config) else { return false }
    let manifest = URL(fileURLWithPath: root + "/manifest.json")
    let content = root + "/content"
    guard fm.fileExists(atPath: content),
          let data = try? Data(contentsOf: manifest),
          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          record["id"] as? String == id,
          let created = record["createdAtEpoch"] as? Double,
          let days = record["retentionDays"] as? Int else { return false }
    return Date().timeIntervalSince1970 - created < Double(days * 86400)
}

func backupContentURL(_ pair: SyncPair, id: String, name: String, config: SyncConfig) -> URL? {
    guard backupAvailable(pair, id: id, config: config),
          let root = backupDirectory(pair, id: id, config: config) else { return nil }
    let manifest = URL(fileURLWithPath: root + "/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          record["name"] as? String == name else { return nil }
    return URL(fileURLWithPath: root + "/content")
}

struct SyncPair: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "新路径"
    var localPath: String = ""
    var cloudPath: String = ""
    var scheduledDirection: String = "merge"
    var enabled: Bool = false
    var syncCodexFiles = true
    var syncClaudeFiles = true
    var syncTemporaryFiles = false
    /// .gitignore-style rules, one per line; matching paths are never synced.
    var excludeRules = ""

    enum CodingKeys: String, CodingKey {
        case id, name, localPath, cloudPath, scheduledDirection, enabled
        case syncCodexFiles, syncClaudeFiles, syncTemporaryFiles, excludeRules
    }

    /// The rule lines that sync_merge.py receives as --exclude.
    var excludePatterns: [String] {
        excludeRules.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    init(id: UUID = UUID(), name: String = "新路径", localPath: String = "", cloudPath: String = "",
         scheduledDirection: String = "merge", enabled: Bool = false,
         syncCodexFiles: Bool = true, syncClaudeFiles: Bool = true, syncTemporaryFiles: Bool = false,
         excludeRules: String = "") {
        self.id = id
        self.name = name
        self.localPath = localPath
        self.cloudPath = cloudPath
        self.scheduledDirection = scheduledDirection
        self.enabled = enabled
        self.syncCodexFiles = syncCodexFiles
        self.syncClaudeFiles = syncClaudeFiles
        self.syncTemporaryFiles = syncTemporaryFiles
        self.excludeRules = excludeRules
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        id = try data.decode(UUID.self, forKey: .id)
        name = try data.decode(String.self, forKey: .name)
        localPath = try data.decode(String.self, forKey: .localPath)
        cloudPath = try data.decode(String.self, forKey: .cloudPath)
        scheduledDirection = try data.decode(String.self, forKey: .scheduledDirection)
        enabled = try data.decode(Bool.self, forKey: .enabled)
        syncCodexFiles = try data.decodeIfPresent(Bool.self, forKey: .syncCodexFiles) ?? true
        syncClaudeFiles = try data.decodeIfPresent(Bool.self, forKey: .syncClaudeFiles) ?? true
        // Existing copies are retained in the anchor; an omitted preference skips
        // build scratch directories without interpreting them as deletions.
        syncTemporaryFiles = try data.decodeIfPresent(Bool.self, forKey: .syncTemporaryFiles) ?? false
        excludeRules = try data.decodeIfPresent(String.self, forKey: .excludeRules) ?? ""
    }

    var isUnusedDefaultPlaceholder: Bool {
        name == "新路径" && localPath.isEmpty && cloudPath.isEmpty &&
            scheduledDirection == "merge" && !enabled
    }
}

struct SyncConfig: Codable, Equatable {
    var pairs: [SyncPair] = []
    var intervalHours = 24
    var scheduleMode = "daily"
    var dailyHour = 23
    var dailyMinute = 0
    var excludeLatexIntermediates = true
    var conflictPolicy = "keep-both"
    var backupRetentionDays = 15
    var enabled = true
    var language = "zh-Hans"
    var notificationMode = "off"
    var checkForUpdates = true
    var autoInstallUpdates = false
    var cloudConfigEnabled = false
    var oneDriveRoot = ""
    var localRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
    var cloudImportAnchors: [String: CloudImportAnchor] = [:]
    /// "local" (beside the merge state), "icloud" or "folder" (backupFolder).
    var backupLocation = "local"
    var backupFolder = ""
    /// Before each sync, skip pairs whose cloud provider folder is offline.
    var checkCloudBeforeSync = true

    enum CodingKeys: String, CodingKey {
        case pairs, intervalHours, nightlyAt23, scheduleMode, dailyHour, dailyMinute
        case excludeLatexIntermediates, conflictPolicy, backupRetentionDays, enabled, language, notificationMode
        case checkForUpdates, autoInstallUpdates, cloudConfigEnabled, oneDriveRoot, localRoot, cloudImportAnchors
        case backupLocation, backupFolder, checkCloudBeforeSync
        case source, destination, scheduledDirection
    }

    init() {}

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        intervalHours = try data.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 24
        let oldNightly = try data.decodeIfPresent(Bool.self, forKey: .nightlyAt23) ?? true
        scheduleMode = try data.decodeIfPresent(String.self, forKey: .scheduleMode) ?? (oldNightly ? "daily" : "interval")
        dailyHour = try data.decodeIfPresent(Int.self, forKey: .dailyHour) ?? 23
        dailyMinute = try data.decodeIfPresent(Int.self, forKey: .dailyMinute) ?? 0
        excludeLatexIntermediates = try data.decodeIfPresent(Bool.self, forKey: .excludeLatexIntermediates) ?? true
        conflictPolicy = try data.decodeIfPresent(String.self, forKey: .conflictPolicy) ?? "keep-both"
        backupRetentionDays = try data.decodeIfPresent(Int.self, forKey: .backupRetentionDays) ?? 15
        enabled = try data.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        language = try data.decodeIfPresent(String.self, forKey: .language) ?? "zh-Hans"
        notificationMode = try data.decodeIfPresent(String.self, forKey: .notificationMode) ?? "off"
        checkForUpdates = try data.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        autoInstallUpdates = try data.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? false
        cloudConfigEnabled = try data.decodeIfPresent(Bool.self, forKey: .cloudConfigEnabled) ?? false
        oneDriveRoot = try data.decodeIfPresent(String.self, forKey: .oneDriveRoot) ?? ""
        localRoot = try data.decodeIfPresent(String.self, forKey: .localRoot)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").path
        cloudImportAnchors = try data.decodeIfPresent([String: CloudImportAnchor].self, forKey: .cloudImportAnchors) ?? [:]
        backupLocation = try data.decodeIfPresent(String.self, forKey: .backupLocation) ?? "local"
        backupFolder = try data.decodeIfPresent(String.self, forKey: .backupFolder) ?? ""
        checkCloudBeforeSync = try data.decodeIfPresent(Bool.self, forKey: .checkCloudBeforeSync) ?? true
        if let saved = try data.decodeIfPresent([SyncPair].self, forKey: .pairs) {
            pairs = saved.filter { !$0.isUnusedDefaultPlaceholder }
        } else {
            let local = try data.decodeIfPresent(String.self, forKey: .source) ?? ""
            let cloud = try data.decodeIfPresent(String.self, forKey: .destination) ?? ""
            let direction = try data.decodeIfPresent(String.self, forKey: .scheduledDirection) ?? "upload"
            pairs = [SyncPair(name: "已导入路径", localPath: local, cloudPath: cloud,
                              scheduledDirection: direction, enabled: !local.isEmpty && !cloud.isEmpty)]
        }
        if oneDriveRoot.isEmpty {
            let roots = Set(pairs.compactMap { inferredOneDriveRoot($0.cloudPath) })
            if roots.count == 1 { oneDriveRoot = roots.first ?? "" }
        }
    }

    func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(pairs, forKey: .pairs)
        try data.encode(intervalHours, forKey: .intervalHours)
        try data.encode(scheduleMode, forKey: .scheduleMode)
        try data.encode(dailyHour, forKey: .dailyHour)
        try data.encode(dailyMinute, forKey: .dailyMinute)
        try data.encode(excludeLatexIntermediates, forKey: .excludeLatexIntermediates)
        try data.encode(conflictPolicy, forKey: .conflictPolicy)
        try data.encode(backupRetentionDays, forKey: .backupRetentionDays)
        try data.encode(enabled, forKey: .enabled)
        try data.encode(language, forKey: .language)
        try data.encode(notificationMode, forKey: .notificationMode)
        try data.encode(checkForUpdates, forKey: .checkForUpdates)
        try data.encode(autoInstallUpdates, forKey: .autoInstallUpdates)
        try data.encode(cloudConfigEnabled, forKey: .cloudConfigEnabled)
        try data.encode(oneDriveRoot, forKey: .oneDriveRoot)
        try data.encode(localRoot, forKey: .localRoot)
        try data.encode(cloudImportAnchors, forKey: .cloudImportAnchors)
        try data.encode(backupLocation, forKey: .backupLocation)
        try data.encode(backupFolder, forKey: .backupFolder)
        try data.encode(checkCloudBeforeSync, forKey: .checkCloudBeforeSync)
    }
}

extension SyncConfig {
    /// The existing folder that receives backups, or nil to keep them on this Mac.
    var backupBaseFolder: String? {
        switch backupLocation {
        case "icloud": return CloudConfigStore.iCloudDrive.path
        case "folder": return backupFolder.isEmpty ? nil : backupFolder
        default: return nil
        }
    }

    /// The folder shown to the person and checked against every sync path.
    var backupDisplayFolder: String? {
        guard let base = backupBaseFolder else { return nil }
        return backupLocation == "icloud" ? base + "/PathSync/Backups" : base
    }

    func backupSubpath(_ pair: SyncPair) -> String {
        let id = pair.id.uuidString.lowercased()
        return backupLocation == "icloud" ? "PathSync/Backups/" + id : id
    }

    func remoteBackupDirectory(_ pair: SyncPair) -> String? {
        backupBaseFolder.map { $0 + "/" + backupSubpath(pair) }
    }

    func backupArguments(_ pair: SyncPair) -> [String] {
        guard let base = backupBaseFolder else { return [] }
        return ["--backup-root", base, "--backup-subpath", backupSubpath(pair)]
    }
}

func validatedBackupLocation(_ config: SyncConfig) throws {
    guard ["local", "icloud", "folder"].contains(config.backupLocation) else {
        throw NSError(domain: appID, code: 16, userInfo: [NSLocalizedDescriptionKey: "未知的备份位置。"])
    }
    if config.backupLocation == "folder" && config.backupFolder.isEmpty {
        throw NSError(domain: appID, code: 16, userInfo: [NSLocalizedDescriptionKey: "请选择用于存放备份的文件夹。"])
    }
    guard let folder = config.backupDisplayFolder else { return }
    let backups = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
    for pair in config.pairs {
        for path in [pair.localPath, pair.cloudPath] where !path.isEmpty {
            let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            if backups == root || backups.hasPrefix(root + "/") || root.hasPrefix(backups + "/") {
                throw NSError(domain: appID, code: 17, userInfo: [NSLocalizedDescriptionKey:
                    "备份位置不能位于「\(pair.name)」的同步路径内，也不能包含它：\(root)"])
            }
        }
    }
}

func inferredOneDriveRoot(_ path: String) -> String? {
    guard !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let parts = url.pathComponents
    guard let index = parts.firstIndex(where: { $0.hasPrefix("OneDrive-") }),
          index >= 3, parts[index - 2] == "Library", parts[index - 1] == "CloudStorage" else {
        return nil
    }
    return NSString.path(withComponents: Array(parts[...index]))
}

enum SyncDirection: String {
    case upload, download, merge
    var label: String {
        switch self {
        case .upload: return "本地 → 云端"
        case .download: return "云端 → 本地"
        case .merge: return "双向合并"
        }
    }
}

func loadConfig(_ path: String = defaultConfigPath) throws -> SyncConfig {
    if !fm.fileExists(atPath: path) { return SyncConfig() }
    return try JSONDecoder().decode(SyncConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

func saveConfig(_ config: SyncConfig, at path: String = defaultConfigPath) throws {
    let url = URL(fileURLWithPath: path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    if fm.fileExists(atPath: path) {
        let previous = try Data(contentsOf: url)
        if previous == data { return }
        let backups = url.deletingLastPathComponent().appendingPathComponent("config-backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let snapshot = backups.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json")
        try previous.write(to: snapshot, options: .atomic)
        let files = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.contentModificationDateKey])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in files.dropFirst(20) { try? fm.removeItem(at: stale) }
    }
    try data.write(to: url, options: .atomic)
}

struct ConfigSnapshot: Identifiable {
    let url: URL
    let date: Date
    var id: String { url.path }
}

func configSnapshots(at path: String = defaultConfigPath) -> [ConfigSnapshot] {
    let folder = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("config-backups")
    let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { url in
        guard (try? loadConfig(url.path)) != nil else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return ConfigSnapshot(url: url, date: date)
    }.sorted { $0.date > $1.date }
}

func validatedPaths(_ pair: SyncPair) throws -> (String, String) {
    guard !pair.localPath.trimmingCharacters(in: .whitespaces).isEmpty,
          !pair.cloudPath.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw NSError(domain: appID, code: 1, userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」需要选择本地和云端目录。"])
    }
    let local = URL(fileURLWithPath: pair.localPath).standardizedFileURL.resolvingSymlinksInPath().path
    let cloud = URL(fileURLWithPath: pair.cloudPath).standardizedFileURL.resolvingSymlinksInPath().path
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: local, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: appID, code: 2, userInfo: [NSLocalizedDescriptionKey: "本地目录不存在：\(local)"])
    }
    isDirectory = false
    guard fm.fileExists(atPath: cloud, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: appID, code: 3, userInfo: [NSLocalizedDescriptionKey: "云端目录不存在：\(cloud)"])
    }
    guard local != cloud, !local.hasPrefix(cloud + "/"), !cloud.hasPrefix(local + "/") else {
        throw NSError(domain: appID, code: 4, userInfo: [NSLocalizedDescriptionKey: "同一组路径不能相同或互相包含。"])
    }
    return (local, cloud)
}

func validatedPairSet(_ pairs: [SyncPair], including selectedID: UUID? = nil) throws {
    var roots: [(name: String, path: String)] = []
    for pair in pairs where pair.enabled || pair.id == selectedID {
        let local: String
        let cloud: String
        if selectedID == nil || pair.id == selectedID {
            (local, cloud) = try validatedPaths(pair)
        } else {
            guard !pair.localPath.isEmpty, !pair.cloudPath.isEmpty else { continue }
            local = URL(fileURLWithPath: pair.localPath).standardizedFileURL.resolvingSymlinksInPath().path
            cloud = URL(fileURLWithPath: pair.cloudPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        for candidate in [local, cloud] {
            if let other = roots.first(where: { existing in
                candidate == existing.path || candidate.hasPrefix(existing.path + "/") ||
                    existing.path.hasPrefix(candidate + "/")
            }) {
                throw NSError(domain: appID, code: 14, userInfo: [NSLocalizedDescriptionKey:
                    "「\(pair.name)」与「\(other.name)」的同步目录重叠：\(candidate)。请只保留一组覆盖此目录。"])
            }
            roots.append((pair.name, candidate))
        }
    }
}

struct PendingConflict: Identifiable {
    let name: String
    let localBytes: Int64
    let cloudBytes: Int64
    let sidecar: String?
    let localMissing: Bool
    let cloudMissing: Bool
    let isTree: Bool
    let blockedByTree: String?
    var id: String { name }
    var isReview: Bool { sidecar != nil }
}

private struct StoredConflict: Decodable {
    let local: [Int64]?
    let cloud: [Int64]?
    let status: String?
    let sidecar: String?
    let kind: String?
}

private struct ConflictState: Decodable {
    let local: String
    let cloud: String
    let conflicts: [String: StoredConflict]?
}

/// Moves aside a merge state left over from the pair's previous roots when it holds no conflicts,
/// so editing a pair's paths starts a fresh baseline instead of failing the consistency check.
/// States that still hold conflicts are kept and keep failing, so no conflict record is lost.
/// The File Provider folder (e.g. "OneDrive-Personal") that holds a path, if any.
func cloudStorageProvider(_ path: String) -> String? {
    let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard let index = parts.firstIndex(of: "CloudStorage"), index >= 2,
          parts[index - 1] == "Library", parts.indices.contains(index + 1) else { return nil }
    return parts[index + 1]
}

func oneDriveIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
        (app.bundleIdentifier ?? "").hasPrefix("com.microsoft.OneDrive")
            || app.localizedName == "OneDrive"
    }
}

/// Lists a folder on a background thread, so an offline provider cannot hang the sync.
func folderResponds(_ path: String, within seconds: Double = 20) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let result = NSLock()
    var listed = false
    DispatchQueue.global(qos: .utility).async {
        let ok = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        result.lock(); listed = ok; result.unlock()
        done.signal()
    }
    guard done.wait(timeout: .now() + seconds) == .success else { return false }
    result.lock(); defer { result.unlock() }
    return listed
}

/// Explains why a pair should be skipped before syncing, or nil when it can run.
/// A skipped pair is never scanned, so an offline provider cannot read as deletions.
func cloudPrecheckProblem(_ pair: SyncPair, language: String,
                          isOneDriveRunning: () -> Bool = oneDriveIsRunning,
                          responds: (String) -> Bool = { folderResponds($0) }) -> String? {
    for path in [pair.cloudPath, pair.localPath] {
        guard let provider = cloudStorageProvider(path) else { continue }
        if provider.hasPrefix("OneDrive") && !isOneDriveRunning() {
            return String(format: uiText("precheckNotRunning", language: language), pair.name)
        }
        if !responds(path) {
            return String(format: uiText("precheckNoResponse", language: language), pair.name, provider)
        }
    }
    return nil
}

/// Whether the merge state belongs to the pair's previous roots and can be retired.
/// Throws when it still holds conflicts. Reads only.
func mergeStateIsStale(_ pair: SyncPair) throws -> Bool {
    let path = mergeStatePath(pair)
    guard fm.fileExists(atPath: path) else { return false }
    let state = try JSONDecoder().decode(ConflictState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let local = URL(fileURLWithPath: pair.localPath).standardizedFileURL.resolvingSymlinksInPath().path
    let cloud = URL(fileURLWithPath: pair.cloudPath).standardizedFileURL.resolvingSymlinksInPath().path
    guard state.local != local || state.cloud != cloud else { return false }
    var isDirectory: ObjCBool = false
    guard (state.conflicts ?? [:]).isEmpty,
          fm.fileExists(atPath: local, isDirectory: &isDirectory), isDirectory.boolValue,
          fm.fileExists(atPath: cloud, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw NSError(domain: appID, code: 10, userInfo: [NSLocalizedDescriptionKey:
            "「\(pair.name)」的路径与冲突记录不一致：记录对应 \(state.local)，当前为 \(local)。请先在原路径处理完冲突，或检查路径配置。"])
    }
    return true
}

func retireStaleMergeState(_ pair: SyncPair) throws {
    guard try mergeStateIsStale(pair) else { return }
    let path = mergeStatePath(pair)
    let local = URL(fileURLWithPath: pair.localPath).standardizedFileURL.resolvingSymlinksInPath().path
    let previous = (try? JSONDecoder().decode(ConflictState.self,
                                              from: Data(contentsOf: URL(fileURLWithPath: path))))?.local ?? ""
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let retired = URL(fileURLWithPath: path).deletingPathExtension().path + ".retired-\(stamp).json"
    try fm.moveItem(atPath: path, toPath: retired)
    appendLog("「\(pair.name)」路径已从 \(previous) 改为 \(local)，旧合并状态已移至 \(retired)")
}

/// Reads only: a stale state without conflicts lists nothing and is retired by the next real sync.
func pendingConflicts(for pair: SyncPair) throws -> [PendingConflict] {
    if try mergeStateIsStale(pair) { return [] }
    let path = mergeStatePath(pair)
    guard fm.fileExists(atPath: path) else { return [] }
    let state = try JSONDecoder().decode(ConflictState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let records = state.conflicts ?? [:]
    let treeNames = records.compactMap { name, record in record.kind == "tree" ? name : nil }
    return records.map { name, record in
        PendingConflict(name: name, localBytes: record.local?.first ?? 0,
                        cloudBytes: record.cloud?.first ?? 0,
                        sidecar: record.status == "preserved" ? record.sidecar : nil,
                        localMissing: record.local == nil, cloudMissing: record.cloud == nil,
                        isTree: record.kind == "tree",
                        blockedByTree: treeNames.first { name.hasPrefix($0 + "/") })
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

private let logLock = NSLock()

/// Folder pairs run in parallel; each message, including multi-line output,
/// is appended as one contiguous write so the history parser can pair it.
func appendLog(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }
    try? fm.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

/// True while another process or thread holds the sync lock. Takes nothing.
func syncIsRunning() -> Bool {
    let lockFD = open(supportDirectory + "/sync.lock", O_RDWR)
    guard lockFD >= 0 else { return false }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_SH | LOCK_NB) == 0 else { return true }
    flock(lockFD, LOCK_UN)
    return false
}

/// The --status report for Shortcuts and scripts: read-only JSON.
func syncStatusJSON(_ config: SyncConfig) -> String {
    let history = (try? readSyncHistory(at: logPath)) ?? []
    let formatter = ISO8601DateFormatter()
    let pairs: [[String: Any]] = config.pairs.map { pair in
        let record = history.first { record in
            !record.isPreview && (
                (record.sourcePath == pair.localPath && record.destinationPath == pair.cloudPath)
                || (record.sourcePath == pair.cloudPath && record.destinationPath == pair.localPath))
        }
        let result: String
        switch record {
        case nil: result = "never"
        case let record? where record.finishedAt == nil || record.hasFailures: result = "incomplete"
        case let record? where record.needsAttention: result = "attention"
        default: result = "ok"
        }
        var entry: [String: Any] = [
            "id": pair.id.uuidString, "name": pair.name, "enabled": pair.enabled,
            "direction": pair.scheduledDirection, "lastResult": result,
            "pendingConflicts": (try? pendingConflicts(for: pair).count) ?? 0
        ]
        if let record { entry["lastSync"] = formatter.string(from: record.finishedAt ?? record.startedAt) }
        return entry
    }
    let report: [String: Any] = ["running": syncIsRunning(), "scheduledSync": config.enabled, "pairs": pairs]
    let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func withSyncLock<T>(_ body: () throws -> T) throws -> T {
    try fm.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
    let lockFD = open(supportDirectory + "/sync.lock", O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { throw NSError(domain: appID, code: 5, userInfo: [NSLocalizedDescriptionKey: "无法创建同步锁。"]) }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        throw NSError(domain: appID, code: 6, userInfo: [NSLocalizedDescriptionKey: "已有同步任务正在运行。"])
    }
    return try body()
}

private func syncOne(_ pair: SyncPair, direction: SyncDirection, excludeLatex: Bool,
                     conflictPolicy: String, backupRetentionDays: Int, dryRun: Bool,
                     plan: Bool = false, backupArguments: [String] = [], language: String,
                     checkCloud: Bool = false,
                     progress: ((UUID, String) -> Void)?) throws -> String {
    if checkCloud, let problem = cloudPrecheckProblem(pair, language: language) {
        // Logged as a run so History shows the skipped pair and its reason.
        appendLog("\(dryRun ? "预览" : "开始") [\(pair.name)] \(direction.label)：\(pair.localPath) → \(pair.cloudPath)")
        throw NSError(domain: appID, code: 19, userInfo: [NSLocalizedDescriptionKey: problem])
    }
    let (local, cloud) = try validatedPaths(pair)
    // A preview never moves files: it plans against an empty baseline instead,
    // which is what the real sync uses after retiring the stale state.
    var statePath = mergeStatePath(pair)
    if dryRun {
        if try mergeStateIsStale(pair) {
            statePath = supportDirectory + "/merge-state/preview-" + UUID().uuidString.lowercased() + ".json"
        }
    } else {
        try retireStaleMergeState(pair)
    }
    let (source, destination) = direction == .download ? (cloud, local) : (local, cloud)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
    var arguments = [helper, local, cloud, statePath, "--direction", direction.rawValue,
                     "--conflict-policy", conflictPolicy,
                     "--backup-retention-days", String(backupRetentionDays)]
    if excludeLatex { arguments.append("--exclude-latex") }
    if !pair.syncCodexFiles { arguments.append("--skip-codex") }
    if !pair.syncClaudeFiles { arguments.append("--skip-claude") }
    if pair.syncTemporaryFiles { arguments.append("--include-temp") }
    // --exclude=VALUE keeps a rule that starts with "-" from reading as an option.
    arguments += pair.excludePatterns.map { "--exclude=" + $0 }
    if checkCloud && cloudStorageProvider(pair.cloudPath) != nil { arguments.append("--hydrate-online-only") }
    if dryRun { arguments.append("--dry-run") }
    if dryRun && plan { arguments.append("--plan-json") }
    arguments += backupArguments
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    appendLog("\(dryRun ? "预览" : "开始") [\(pair.name)] \(direction.label)：\(source) → \(destination)")
    try process.run()
    let activityLock = NSLock()
    var lastActivity = Date()
    var inactivityTimedOut = false
    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    watchdog.schedule(deadline: .now() + 30, repeating: 30)
    watchdog.setEventHandler {
        activityLock.lock()
        let stalled = Date().timeIntervalSince(lastActivity) >= 180
        if stalled { inactivityTimedOut = true }
        activityLock.unlock()
        if stalled && process.isRunning { process.terminate() }
    }
    watchdog.resume()
    defer { watchdog.cancel() }
    var collected = Data()
    var lineBuffer = Data()
    while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        activityLock.lock()
        lastActivity = Date()
        activityLock.unlock()
        collected.append(chunk)
        lineBuffer.append(chunk)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let line = String(decoding: lineBuffer[..<newline], as: UTF8.self)
            lineBuffer.removeSubrange(...newline)
            let fields = line.split(separator: "\t")
            guard fields.first == "PROGRESS", let progress else { continue }
            if fields.count == 5, fields[1] == "SCAN" || fields[1] == "SCAN_DONE" {
                let side = uiText(fields[2] == "cloud" ? "cloud" : "local", language: language)
                progress(pair.id, String(format: uiText("scanProgress", language: language),
                                         pair.name, side, String(fields[3]), String(fields[4])))
            } else if fields.count == 4, fields[1] == "PROCESS" {
                progress(pair.id, String(format: uiText("processProgress", language: language),
                                         pair.name, String(fields[2]), String(fields[3])))
            } else if fields.count == 4, fields[1] == "PREFETCH" {
                progress(pair.id, String(format: uiText("prefetchProgress", language: language),
                                         pair.name, String(fields[2]), String(fields[3])))
            } else if fields.count >= 3, fields[1] == "FILE" {
                progress(pair.id, String(format: uiText("fileProgress", language: language),
                                         pair.name, fields.dropFirst(2).joined(separator: "\t")))
            } else if fields.count >= 4, fields[1] == "WAIT" {
                progress(pair.id, String(format: uiText("waitingForCloud", language: language),
                                         pair.name, String(fields[2]), String(fields[3])))
            }
        }
    }
    let result = String(decoding: collected, as: UTF8.self)
        .components(separatedBy: "\n")
        .filter { !$0.hasPrefix("PROGRESS\t") }
        .joined(separator: "\n")
    process.waitUntilExit()
    appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(strippingSyncPlan(result).trimmingCharacters(in: .whitespacesAndNewlines))")
    activityLock.lock()
    let stalled = inactivityTimedOut
    activityLock.unlock()
    if stalled {
        throw NSError(domain: appID, code: 15, userInfo: [NSLocalizedDescriptionKey:
            "「\(pair.name)」连续 3 分钟未收到 OneDrive 文件系统响应，已停止本次运行；其他路径继续同步。"])
    }
    // A preview that finds conflicts or unreadable files exits with 2, yet its
    // plan is complete and is exactly what the person needs to see.
    let completePreview = dryRun && plan && process.terminationStatus == 2 && parseSyncPlan(result) != nil
    guard process.terminationStatus == 0 || completePreview else {
        let summary = strippingSyncPlan(result).split(separator: "\n").last.map(String.init) ?? "退出码 \(process.terminationStatus)"
        throw NSError(domain: appID, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」未完全成功：\(summary)。详情见同步记录。"])
    }
    return result
}

func resolvePendingConflict(_ pair: SyncPair, name: String, choice: String,
                            retentionDays: Int = 15, backupArguments: [String] = []) throws -> String {
    guard ["local", "cloud", "both", "newest"].contains(choice) else {
        throw NSError(domain: appID, code: 11, userInfo: [NSLocalizedDescriptionKey: "无效的冲突处理方式。"])
    }
    return try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--resolve", name,
                             "--choice", choice, "--backup-retention-days", String(retentionDays)]
            + backupArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        appendLog("开始 [\(pair.name)] 手动处理：\(local) → \(cloud)")
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard process.terminationStatus == 0 else {
            throw NSError(domain: appID, code: 12, userInfo: [NSLocalizedDescriptionKey: "「\(name)」处理失败：\(result.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return result
    }
}

func acknowledgePreservedConflict(_ pair: SyncPair, name: String,
                                  backupArguments: [String] = []) throws -> String {
    try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--acknowledge", name]
            + backupArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        appendLog("开始 [\(pair.name)] 手动处理：\(local) → \(cloud)")
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard process.terminationStatus == 0 else {
            throw NSError(domain: appID, code: 12, userInfo: [NSLocalizedDescriptionKey: result.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return result
    }
}

func resolvePreservedNewest(_ pair: SyncPair, name: String, retentionDays: Int,
                            backupArguments: [String] = []) throws -> String {
    try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--review-newest", name,
                             "--backup-retention-days", String(retentionDays)] + backupArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        appendLog("开始 [\(pair.name)] 手动处理：\(local) → \(cloud)")
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard process.terminationStatus == 0 else {
            throw NSError(domain: appID, code: 14, userInfo: [NSLocalizedDescriptionKey: result.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return result
    }
}

func restoreSavedBackup(_ pair: SyncPair, id: String, retentionDays: Int,
                        backupArguments: [String] = []) throws -> String {
    try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--restore", id,
                             "--backup-retention-days", String(retentionDays)] + backupArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        appendLog("开始 [\(pair.name)] 恢复备份：\(local) → \(cloud)")
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard process.terminationStatus == 0 else {
            throw NSError(domain: appID, code: 13, userInfo: [NSLocalizedDescriptionKey: result.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return result
    }
}

/// Total size of backups still kept beside the merge state.
func localBackupBytes(_ pairs: [SyncPair]) -> Int64 {
    var total: Int64 = 0
    for folder in pairs.flatMap(localBackupFolders) {
        guard let items = fm.enumerator(at: URL(fileURLWithPath: folder),
                                        includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
        for case let item as URL in items {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
    }
    return total
}

/// Copies every local backup to the chosen backup folder, verifies it, then
/// removes the local copy. Returns how many backups moved and how many remain.
func moveLocalBackups(_ config: SyncConfig) throws -> (moved: Int, remaining: Int) {
    guard config.backupBaseFolder != nil else { return (0, 0) }
    try validatedBackupLocation(config)
    return try withSyncLock {
        var moved = 0
        var remaining = 0
        for pair in config.pairs where !pair.localPath.isEmpty && !pair.cloudPath.isEmpty
            && localBackupFolders(pair).contains(where: { fm.fileExists(atPath: $0) }) {
            let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [helper, pair.localPath, pair.cloudPath, mergeStatePath(pair),
                                 "--migrate-backups"] + config.backupArguments(pair)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            appendLog("移动备份 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
            func count(_ key: String) -> Int {
                result.components(separatedBy: key + "=").dropFirst().compactMap { Int($0.prefix(while: \.isNumber)) }.first ?? 0
            }
            if process.terminationStatus != 0 && count("backups_pending") == 0 {
                let message = result.split(separator: "\n").last.map(String.init) ?? "退出码 \(process.terminationStatus)"
                throw NSError(domain: appID, code: 18, userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」的备份未能移动：\(message)"])
            }
            moved += count("backups_moved")
            remaining += count("backups_pending")
        }
        return (moved, remaining)
    }
}

/// Pairs never share or nest a directory (validatedPairSet), and each keeps its
/// own merge state and backups, so a few can run at once under the global lock.
let maxParallelPairs = 3

func selectedPairs(_ config: SyncConfig, pairID: UUID?) -> [SyncPair] {
    config.pairs.filter { pairID == nil ? $0.enabled : $0.id == pairID }
}

private func runPairs(_ config: SyncConfig, pairID: UUID?, direction: SyncDirection?,
                      dryRun: Bool, plan: Bool,
                      progress: ((UUID, String) -> Void)?) throws -> [(SyncPair, Result<String, Error>)] {
    let selected = selectedPairs(config, pairID: pairID)
    guard !selected.isEmpty else {
        throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "没有可同步的路径。"])
    }
    return try withSyncLock {
        try validatedPairSet(config.pairs, including: pairID)
        var results = [Result<String, Error>?](repeating: nil, count: selected.count)
        let resultsLock = NSLock()
        let slots = DispatchSemaphore(value: maxParallelPairs)
        let group = DispatchGroup()
        for (index, pair) in selected.enumerated() {
            slots.wait()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    slots.signal()
                    group.leave()
                }
                let chosen = direction ?? SyncDirection(rawValue: pair.scheduledDirection) ?? .upload
                let result = Result {
                    try syncOne(pair, direction: chosen,
                                excludeLatex: config.excludeLatexIntermediates,
                                conflictPolicy: config.conflictPolicy,
                                backupRetentionDays: config.backupRetentionDays,
                                dryRun: dryRun, plan: plan,
                                backupArguments: config.backupArguments(pair), language: config.language,
                                checkCloud: config.checkCloudBeforeSync,
                                progress: progress)
                }
                if case .failure(let error) = result {
                    appendLog("失败 [\(pair.name)]：\(error.localizedDescription)")
                }
                resultsLock.lock()
                results[index] = result
                resultsLock.unlock()
            }
        }
        group.wait()
        return zip(selected, results.compactMap { $0 }).map { ($0, $1) }
    }
}

@discardableResult
func runSync(_ config: SyncConfig, pairID: UUID? = nil, direction: SyncDirection? = nil,
             dryRun: Bool = false, progress: ((UUID, String) -> Void)? = nil) throws -> String {
    let results = try runPairs(config, pairID: pairID, direction: direction,
                               dryRun: dryRun, plan: false, progress: progress)
    var outputs: [String] = []
    var errors: [String] = []
    for (pair, result) in results {
        switch result {
        case .success(let output): outputs.append("[\(pair.name)] \(output)")
        case .failure(let error): errors.append(error.localizedDescription)
        }
    }
    if !errors.isEmpty {
        throw NSError(domain: appID, code: 8, userInfo: [NSLocalizedDescriptionKey: "\(results.count - errors.count)/\(results.count) 组完成；\(errors.joined(separator: "；"))"])
    }
    return outputs.joined(separator: "\n")
}

/// Runs each selected pair with --dry-run --plan-json. Nothing in either folder
/// or in the merge state is written; only the sync log records the preview.
func previewSync(_ config: SyncConfig, pairID: UUID? = nil,
                 progress: ((UUID, String) -> Void)? = nil) throws -> [PairPreview] {
    let results = try runPairs(config, pairID: pairID, direction: nil,
                               dryRun: true, plan: true, progress: progress)
    return results.map { pair, result in
        let direction = SyncDirection(rawValue: pair.scheduledDirection) ?? .upload
        switch result {
        case .success(let output):
            let plan = parseSyncPlan(output)
            return PairPreview(pairID: pair.id, pairName: pair.name, direction: direction.rawValue,
                               plan: plan, error: plan == nil ? strippingSyncPlan(output) : nil)
        case .failure(let error):
            return PairPreview(pairID: pair.id, pairName: pair.name, direction: direction.rawValue,
                               plan: nil, error: uiError(error, language: config.language))
        }
    }
}

func installSchedule(_ config: SyncConfig) throws {
    try fm.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
    let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let domain = "gui/\(getuid())"
    let old = Process()
    old.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    old.arguments = ["bootout", domain, agentPath]
    old.standardOutput = Pipe()
    old.standardError = Pipe()
    try? old.run()
    old.waitUntilExit()
    if !config.enabled {
        try? fm.removeItem(atPath: agentPath)
        return
    }
    var plist: [String: Any] = [
        "Label": appID, "ProgramArguments": [binary, "--sync"], "RunAtLoad": false,
        "StandardOutPath": supportDirectory + "/launchd.out.log",
        "StandardErrorPath": supportDirectory + "/launchd.err.log"
    ]
    if config.scheduleMode == "daily" {
        plist["StartCalendarInterval"] = ["Hour": min(23, max(0, config.dailyHour)),
                                           "Minute": min(59, max(0, config.dailyMinute))]
    } else { plist["StartInterval"] = min(168, max(6, config.intervalHours)) * 3600 }
    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: URL(fileURLWithPath: agentPath), options: .atomic)
    let start = Process()
    start.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    start.arguments = ["bootstrap", domain, agentPath]
    let errors = Pipe()
    start.standardError = errors
    try start.run()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    start.waitUntilExit()
    guard start.terminationStatus == 0 else {
        throw NSError(domain: appID, code: Int(start.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "定时任务安装失败：\(String(decoding: errorData, as: UTF8.self))"])
    }
}

/// Adds up the key=value summary lines that every pair prints at the end of a run.
func summedCounts(_ output: String) -> [String: Int] {
    var total: [String: Int] = [:]
    for line in output.split(separator: "\n") where line.contains("uploaded=") {
        for word in line.split(separator: " ") {
            let parts = word.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1]) {
                total[String(parts[0].split(separator: "]").last ?? parts[0]).trimmingCharacters(in: .whitespaces), default: 0] += value
            }
        }
    }
    return total
}

final class SyncModel: ObservableObject {
    @Published var config: SyncConfig
    @Published private(set) var savedConfig: SyncConfig
    @Published var selectedID: UUID?
    @Published var page = "overview"
    @Published var statusKey = "ready"
    @Published var statusDetail: String?
    @Published var busy = false
    @Published var conflictsByPair: [UUID: [PendingConflict]] = [:]
    @Published var history: [SyncHistoryRecord] = []
    @Published var historyError: String?
    @Published var confirmingRemoval = false
    @Published var update: UpdateStatus = .idle
    @Published var updateInstallPhase: UpdateInstallPhase = .idle
    @Published var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    @Published var launchAtLoginError: String?
    @Published var lastUpdateCheck: Date?
    @Published var cloudProfiles: [CloudConfiguration] = []
    @Published var cloudError: String?
    @Published var cloudBusy = false
    @Published var lastCloudPublish: Date?
    @Published var ownCloudProfile: CloudConfiguration?
    @Published var ownCloudTransferStatus = "unknown"
    @Published var cloudImportPreview: CloudImportPreview?
    @Published var configBackups: [ConfigSnapshot] = configSnapshots()
    /// The latest dry-run plan; confirming it runs the real sync for the same scope.
    @Published var preview: SyncPreview? {
        didSet {
            // A dismissed preview leaves nothing to confirm.
            if preview == nil && statusKey == "previewReady" {
                statusKey = conflictCount > 0 ? "conflictsPending" : "ready"
                statusDetail = nil
            }
        }
    }
    /// "window" shows the preview as a sheet; "menu" shows it inside the menu bar panel.
    @Published var previewOrigin = "window"
    @Published var syncingPairIDs: Set<UUID> = []
    @Published var pairProgress: [UUID: String] = [:]
    /// Summed counts of the last finished sync, for the result banner.
    @Published var lastRunCounts: [String: Int]?
    @Published var localBackupSize: Int64?
    @Published var backupMoveBusy = false
    @Published var backupMoveMessage: String?
    @Published var diffResult: LatexDiffResult?
    private let refreshQueue = DispatchQueue(label: "com.ensom.ResearchSync.refresh", qos: .utility)
    private let historyReader = SyncHistoryReader(path: logPath)
    /// Touched only on refreshQueue: merge-state files are re-read only after they change.
    private var conflictCache: [UUID: (stamp: String, conflicts: [PendingConflict])] = [:]
    private var refreshTimer: Timer?
    private var lastUpdateAttempt = UserDefaults.standard.object(forKey: "lastUpdateAttempt") as? Date
    private var notificationRequestID = UUID()
    private let cloudDeviceID: UUID = {
        if let value = UserDefaults.standard.string(forKey: "cloudConfigDeviceID"),
           let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "cloudConfigDeviceID")
        return id
    }()

    init() {
        let loaded = (try? loadConfig()) ?? SyncConfig()
        config = loaded
        savedConfig = loaded
        selectedID = loaded.pairs.first?.id
        refreshConflicts()
        refreshHistory()
        if let cached = UserDefaults.standard.data(forKey: "cachedLatestRelease"),
           let release = try? JSONDecoder().decode(AppRelease.self, from: cached) {
            update = updateStatus(for: release, currentVersion: currentVersion)
            lastUpdateCheck = UserDefaults.standard.object(forKey: "lastSuccessfulUpdateCheck") as? Date
        }
        let updateErrorFile = URL(fileURLWithPath: supportDirectory + "/last-update-error.txt")
        if let message = try? String(contentsOf: updateErrorFile, encoding: .utf8) {
            updateInstallPhase = .failed(message)
        }
        DispatchQueue.main.async { self.checkForUpdates(automatic: true) }
        if loaded.cloudConfigEnabled {
            DispatchQueue.main.async { self.refreshCloudProfiles() }
        }
        // One timer for the whole app: the window and the menu bar panel share it.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshState()
            self?.checkForUpdates(automatic: true)
            self?.refreshCloudProfiles()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    var hasUnsavedChanges: Bool { config != savedConfig }
    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    var hasEnabledPairs: Bool { config.pairs.contains { $0.enabled } }
    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var availableRelease: AppRelease? {
        if case .available(let release) = update { return release }
        return nil
    }

    var updateInstallBusy: Bool {
        switch updateInstallPhase {
        case .downloading, .verifying, .replacing: return true
        case .idle, .failed: return false
        }
    }

    func lastRecord(for pair: SyncPair) -> SyncHistoryRecord? {
        history.first { record in
            !record.isPreview && (
                (record.sourcePath == pair.localPath && record.destinationPath == pair.cloudPath)
                || (record.sourcePath == pair.cloudPath && record.destinationPath == pair.localPath))
        }
    }

    var lastSyncDate: Date? {
        history.first { !$0.isPreview }.map { $0.finishedAt ?? $0.startedAt }
    }

    /// Automatic checks honour the setting and run at most once a day; manual checks always run.
    func checkForUpdates(automatic: Bool = false) {
        if update == .checking { return }
        if automatic {
            guard config.checkForUpdates else { return }
            let checkedVersion = UserDefaults.standard.string(forKey: "lastUpdateAttemptAppVersion")
            if checkedVersion == currentVersion, let last = lastUpdateAttempt,
               Date().timeIntervalSince(last) < 86_400 { return }
        }
        lastUpdateAttempt = Date()
        UserDefaults.standard.set(lastUpdateAttempt, forKey: "lastUpdateAttempt")
        UserDefaults.standard.set(currentVersion, forKey: "lastUpdateAttemptAppVersion")
        let previous = update
        update = .checking
        let current = currentVersion
        fetchLatestRelease { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let release):
                    self.lastUpdateCheck = Date()
                    UserDefaults.standard.set(try? JSONEncoder().encode(release), forKey: "cachedLatestRelease")
                    UserDefaults.standard.set(self.lastUpdateCheck, forKey: "lastSuccessfulUpdateCheck")
                    self.update = updateStatus(for: release, currentVersion: current)
                    if self.config.autoInstallUpdates { self.installAvailableUpdate() }
                case .failure:
                    // A silent background failure keeps whatever was known before.
                    self.update = automatic ? previous : .failed
                }
            }
        }
    }

    func installAvailableUpdate() {
        guard let release = availableRelease, release.signatureURL != nil,
              !busy, !hasUnsavedChanges else { return }
        if case .downloading = updateInstallPhase { return }
        if case .verifying = updateInstallPhase { return }
        if case .replacing = updateInstallPhase { return }
        updateInstallPhase = .downloading
        prepareUpdate(release, installedBundle: Bundle.main.bundleURL,
                      status: { phase in DispatchQueue.main.async { self.updateInstallPhase = phase } }) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.updateInstallPhase = .failed(error.localizedDescription)
                case .success(let prepared):
                    do {
                        let process = Process()
                        process.executableURL = prepared.helper
                        process.arguments = [Bundle.main.bundleURL.path, prepared.staged.path,
                                             String(getpid())]
                        process.standardOutput = FileHandle.nullDevice
                        process.standardError = FileHandle.nullDevice
                        try process.run()
                        self.updateInstallPhase = .replacing
                        NSApp.terminate(nil)
                    } catch {
                        self.updateInstallPhase = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    var selectedIndex: Int? { config.pairs.firstIndex { $0.id == selectedID } }
    var selectedPair: SyncPair? { selectedIndex.map { config.pairs[$0] } }
    var selectedConflicts: [PendingConflict] {
        guard let selectedID else { return [] }
        return conflictsByPair[selectedID] ?? []
    }
    var conflictCount: Int { conflictsByPair.values.reduce(0) { $0 + $1.count } }

    func refreshHistory() { refreshState(conflicts: false) }
    func refreshConflicts() { refreshState(history: false) }

    /// Reads merge states and the sync log off the main thread. The log is read
    /// incrementally and a merge state is decoded again only after it changes.
    func refreshState(conflicts: Bool = true, history: Bool = true) {
        let pairs = config.pairs
        let language = config.language
        refreshQueue.async {
            var updated: [UUID: [PendingConflict]]?
            var conflictError: String?
            if conflicts {
                var found: [UUID: [PendingConflict]] = [:]
                for pair in pairs {
                    let path = mergeStatePath(pair)
                    let attributes = try? fm.attributesOfItem(atPath: path)
                    let stamp = [pair.localPath, pair.cloudPath,
                                 String(describing: attributes?[.modificationDate]),
                                 String(describing: attributes?[.size])].joined(separator: "\u{0}")
                    if let cached = self.conflictCache[pair.id], cached.stamp == stamp {
                        found[pair.id] = cached.conflicts
                        continue
                    }
                    do {
                        let current = try pendingConflicts(for: pair)
                        self.conflictCache[pair.id] = (stamp, current)
                        found[pair.id] = current
                    } catch {
                        self.conflictCache[pair.id] = nil
                        conflictError = uiError(error, language: language)
                    }
                }
                updated = found
            }
            let records = history ? Result { () throws -> [SyncHistoryRecord] in
                try self.historyReader.read().filter { record in
                    pairs.contains { pair in
                        (record.sourcePath == pair.localPath && record.destinationPath == pair.cloudPath)
                        || (record.sourcePath == pair.cloudPath && record.destinationPath == pair.localPath)
                    }
                }
            } : nil
            DispatchQueue.main.async {
                if let updated {
                    self.conflictsByPair = updated.filter { id, _ in self.config.pairs.contains { $0.id == id } }
                    if let conflictError {
                        self.statusKey = "error"
                        self.statusDetail = conflictError
                    } else if self.statusKey == "ready" || self.statusKey == "conflictsPending" {
                        self.statusKey = self.conflictCount > 0 ? "conflictsPending" : "ready"
                    }
                }
                switch records {
                case .success(let value)?:
                    self.history = value
                    self.historyError = nil
                case .failure(let error)?:
                    self.historyError = uiError(error, language: language)
                case nil:
                    break
                }
            }
        }
    }

    func pair(_ id: UUID) -> SyncPair? { config.pairs.first { $0.id == id } }

    func lastSync(for pair: SyncPair) -> Date? {
        lastRecord(for: pair).map { $0.finishedAt ?? $0.startedAt }
    }

    func refreshLocalBackupSize() {
        let pairs = savedConfig.pairs
        DispatchQueue.global(qos: .utility).async {
            let size = localBackupBytes(pairs)
            DispatchQueue.main.async { self.localBackupSize = size }
        }
    }

    func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: config.backupFolder.isEmpty
            ? (config.oneDriveRoot.isEmpty ? home + "/Library/CloudStorage" : config.oneDriveRoot)
            : config.backupFolder)
        if panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL.path {
            config.backupFolder = folder
            config.backupLocation = "folder"
        }
    }

    /// Moves backups kept on this Mac into the saved backup folder, verifying each one.
    func moveExistingBackups() {
        guard !busy, !backupMoveBusy, !hasUnsavedChanges, savedConfig.backupBaseFolder != nil else { return }
        backupMoveBusy = true
        backupMoveMessage = nil
        let current = savedConfig
        DispatchQueue.global(qos: .utility).async {
            let outcome = Result { try moveLocalBackups(current) }
            DispatchQueue.main.async {
                self.backupMoveBusy = false
                switch outcome {
                case .success(let result):
                    self.backupMoveMessage = String(format: uiText(result.remaining > 0 ? "backupsMovedPartly" : "backupsMoved",
                                                                   language: current.language),
                                                    result.moved, result.remaining)
                case .failure(let error):
                    self.backupMoveMessage = uiError(error, language: current.language)
                }
                self.refreshLocalBackupSize()
                self.refreshHistory()
            }
        }
    }

    func addPair() {
        let pair = SyncPair()
        config.pairs.append(pair)
        selectedID = pair.id
        page = "pair"
        statusKey = "chooseFoldersHint"
        statusDetail = nil
    }

    func removeSelected() {
        guard let index = selectedIndex else { return }
        config.pairs.remove(at: index)
        selectedID = config.pairs.first?.id
        page = selectedID == nil ? "overview" : "pair"
        statusKey = "removedHint"
        statusDetail = nil
        refreshConflicts()
    }

    func chooseFolder(local: Bool) {
        guard let index = selectedIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            if local { config.pairs[index].localPath = path }
            else { config.pairs[index].cloudPath = path }
            refreshConflicts()
        }
    }

    func chooseOneDriveRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: config.oneDriveRoot.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path + "/Library/CloudStorage"
            : config.oneDriveRoot)
        if panel.runModal() == .OK, let root = panel.url?.standardizedFileURL.path {
            config.oneDriveRoot = root
        }
    }

    func chooseLocalRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: config.localRoot)
        if panel.runModal() == .OK, let root = panel.url?.standardizedFileURL.path {
            config.localRoot = root
        }
    }

    func refreshCloudProfiles() {
        guard config.cloudConfigEnabled, !cloudBusy else { return }
        cloudBusy = true
        let ownID = cloudDeviceID
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> ([CloudConfiguration], CloudConfiguration?, String) in
                let store = CloudConfigStore(root: CloudConfigStore.iCloudRoot)
                let all = try store.readOthers(excluding: UUID())
                return (all.filter { $0.deviceID != ownID }, all.first { $0.deviceID == ownID },
                        store.transferStatus(for: ownID))
            }
            DispatchQueue.main.async {
                self.cloudBusy = false
                switch result {
                case .success(let (profiles, own, status)):
                    self.cloudProfiles = profiles
                    self.ownCloudProfile = own
                    self.ownCloudTransferStatus = status
                    self.cloudError = nil
                case .failure(let error):
                    self.cloudError = cloudConfigErrorText(error, language: self.config.language)
                }
            }
        }
    }

    func importCloudProfile(_ profile: CloudConfiguration) {
        guard !busy, !hasUnsavedChanges else { return }
        do {
            cloudImportPreview = try CloudImportPreview(profile: profile, current: config)
            cloudError = nil
        } catch {
            cloudError = cloudConfigErrorText(error, language: config.language)
        }
    }

    func applyCloudImport(_ preview: CloudImportPreview) {
        do {
            try createImportedLocalFolders(preview)
            config = preview.proposed
            selectedID = config.pairs.first?.id
            cloudImportPreview = nil
            cloudError = nil
            statusKey = "cloudImported"
            statusDetail = nil
            refreshConflicts()
        } catch {
            let message = cloudConfigErrorText(error, language: config.language)
            cloudError = message
            cloudImportPreview = nil
        }
    }

    func restoreConfigSnapshot(_ snapshot: ConfigSnapshot) {
        do {
            let restored = try loadConfig(snapshot.url.path)
            config = restored
            selectedID = restored.pairs.first?.id
            statusKey = "cloudImported"
            statusDetail = nil
            refreshConflicts()
        } catch { statusKey = "error"; statusDetail = error.localizedDescription }
    }

    private func publishCloudConfig(_ saved: SyncConfig) {
        let ownID = cloudDeviceID
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let profile = CloudConfiguration(config: saved, deviceID: ownID, deviceName: deviceName)
        if let ownCloudProfile,
           ownCloudProfile.sharedDigest == profile.sharedDigest,
           ownCloudProfile.importedRevisions == profile.importedRevisions {
            return
        }
        cloudBusy = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try CloudConfigStore(root: CloudConfigStore.iCloudRoot).write(profile)
            }
            DispatchQueue.main.async {
                self.cloudBusy = false
                switch result {
                case .success:
                    self.lastCloudPublish = Date()
                    self.ownCloudProfile = profile
                    self.ownCloudTransferStatus = CloudConfigStore(root: CloudConfigStore.iCloudRoot)
                        .transferStatus(for: ownID)
                    self.cloudError = nil
                    self.refreshCloudProfiles()
                case .failure(let error):
                    self.cloudError = cloudConfigErrorText(error, language: self.config.language)
                }
            }
        }
    }

    func chooseNotificationMode(_ mode: String) {
        notificationRequestID = UUID()
        let requestID = notificationRequestID
        guard mode != "off" else { config.notificationMode = "off"; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                guard self.notificationRequestID == requestID else { return }
                if granted {
                    self.config.notificationMode = mode
                } else {
                    self.config.notificationMode = "off"
                    self.statusKey = "notificationDenied"
                    self.statusDetail = error.map { uiError($0, language: self.config.language) }
                }
            }
        }
    }

    func save() {
        do {
            if config.cloudConfigEnabled && !config.pairs.contains(where: { $0.enabled }) {
                config.enabled = false
            }
            if config.enabled && !config.pairs.contains(where: { $0.enabled }) {
                throw NSError(domain: appID, code: 9, userInfo: [NSLocalizedDescriptionKey: "启用后台同步前，请至少启用一组路径。"])
            }
            try validatedPairSet(config.pairs)
            try validatedBackupLocation(config)
            for pair in config.pairs where pair.enabled {
                _ = try pendingConflicts(for: pair)
            }
            config.intervalHours = min(168, max(6, config.intervalHours))
            config.dailyHour = min(23, max(0, config.dailyHour))
            config.dailyMinute = min(59, max(0, config.dailyMinute))
            if !["keep-both", "ask", "newest"].contains(config.conflictPolicy) {
                config.conflictPolicy = "keep-both"
            }
            config.backupRetentionDays = min(365, max(1, config.backupRetentionDays))
            if !["off", "issues", "all"].contains(config.notificationMode) {
                config.notificationMode = "off"
            }
            try saveConfig(config)
            configBackups = configSnapshots()
            savedConfig = config
            // A plan made with other folders, directions or rules no longer applies.
            preview = nil
            try installSchedule(config)
            statusKey = config.enabled ? "savedEnabled" : "savedDisabled"
            statusDetail = nil
            refreshConflicts()
            if config.cloudConfigEnabled { publishCloudConfig(config) }
            if config.autoInstallUpdates { installAvailableUpdate() }
        } catch { statusKey = "error"; statusDetail = uiError(error, language: config.language) }
    }

    func syncNow(_ direction: SyncDirection? = nil, all: Bool = false, pairID: UUID? = nil) {
        let id = all ? nil : (pairID ?? selectedID)
        guard !busy, !hasUnsavedChanges, all || id != nil else { return }
        busy = true
        preview = nil
        lastRunCounts = nil
        statusKey = all ? "syncingAll" : "syncingPair"
        statusDetail = nil
        let current = config
        syncingPairIDs = Set(selectedPairs(current, pairID: id).map(\.id))
        pairProgress = [:]
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            var counts: [String: Int]?
            do {
                let output = try runSync(current, pairID: id, direction: direction) { pairID, message in
                    DispatchQueue.main.async {
                        self.pairProgress[pairID] = message
                        self.statusDetail = message
                    }
                }
                postSyncNotification(config: current, output: output, failed: false)
                counts = summedCounts(output)
                let reviews = counts?["reviews"] ?? 0
                resultKey = all ? "doneAll" : "donePair"
                resultDetail = reviews > 0
                    ? String(format: uiText("reviewsRemain", language: current.language), reviews)
                    : nil
            } catch {
                postSyncNotification(config: current, output: "", failed: true)
                resultKey = "error"
                resultDetail = uiError(error, language: current.language)
            }
            DispatchQueue.main.async {
                self.statusKey = resultKey
                self.statusDetail = resultDetail
                self.lastRunCounts = counts
                self.busy = false
                self.syncingPairIDs = []
                self.pairProgress = [:]
                self.refreshState()
                if self.config.autoInstallUpdates { self.installAvailableUpdate() }
            }
        }
    }

    /// Builds a dry-run plan for one pair or every enabled pair. Nothing is written.
    func previewNow(pairID: UUID? = nil, origin: String = "window") {
        guard !busy, !hasUnsavedChanges, pairID != nil || hasEnabledPairs else { return }
        busy = true
        preview = nil
        previewOrigin = origin
        statusKey = "previewing"
        statusDetail = nil
        let current = config
        syncingPairIDs = Set(selectedPairs(current, pairID: pairID).map(\.id))
        pairProgress = [:]
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                try previewSync(current, pairID: pairID) { id, message in
                    DispatchQueue.main.async {
                        self.pairProgress[id] = message
                        self.statusDetail = message
                    }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.syncingPairIDs = []
                self.pairProgress = [:]
                switch outcome {
                case .success(let pairs):
                    self.preview = SyncPreview(scope: pairID, createdAt: Date(), pairs: pairs)
                    self.statusKey = "previewReady"
                    self.statusDetail = nil
                case .failure(let error):
                    self.statusKey = "error"
                    self.statusDetail = uiError(error, language: current.language)
                }
                self.refreshHistory()
            }
        }
    }

    func confirmPreview() {
        guard let preview, !busy else { return }
        syncNow(all: preview.scope == nil, pairID: preview.scope)
    }

    func resolveConflict(_ name: String, choice: String, in target: SyncPair? = nil) {
        guard let pair = target ?? selectedPair, !busy, !hasUnsavedChanges else { return }
        let language = config.language
        let retentionDays = config.backupRetentionDays
        let backupArguments = config.backupArguments(pair)
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try resolvePendingConflict(pair, name: name, choice: choice,
                                               retentionDays: retentionDays,
                                               backupArguments: backupArguments)
                resultKey = choice == "both" ? "preservedReview" : "resolved"
                resultDetail = nil
            } catch {
                resultKey = "error"
                resultDetail = uiError(error, language: language)
            }
            DispatchQueue.main.async {
                self.statusKey = resultKey
                self.statusDetail = resultDetail
                self.busy = false
                self.refreshConflicts()
            }
        }
    }

    func acknowledgeConflict(_ name: String, in target: SyncPair? = nil) {
        guard let pair = target ?? selectedPair, !busy else { return }
        let language = config.language
        let backupArguments = config.backupArguments(pair)
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try acknowledgePreservedConflict(pair, name: name, backupArguments: backupArguments)
                resultKey = "reviewAcknowledged"
                resultDetail = nil
            } catch {
                resultKey = "error"
                resultDetail = uiError(error, language: language)
            }
            DispatchQueue.main.async {
                self.statusKey = resultKey
                self.statusDetail = resultDetail
                self.busy = false
                self.refreshConflicts()
            }
        }
    }

    func chooseNewestForReview(_ name: String, in target: SyncPair? = nil) {
        guard let pair = target ?? selectedPair, !busy else { return }
        let language = config.language
        let retentionDays = config.backupRetentionDays
        let backupArguments = config.backupArguments(pair)
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try resolvePreservedNewest(pair, name: name, retentionDays: retentionDays,
                                               backupArguments: backupArguments)
                resultKey = "newestResolved"
                resultDetail = nil
            } catch {
                resultKey = "error"
                resultDetail = uiError(error, language: language)
            }
            DispatchQueue.main.async {
                self.statusKey = resultKey
                self.statusDetail = resultDetail
                self.busy = false
                self.refreshConflicts()
                self.refreshHistory()
            }
        }
    }

    func restoreBackup(pair: SyncPair, id: String) {
        guard !busy, !hasUnsavedChanges else { return }
        let language = config.language
        let retentionDays = config.backupRetentionDays
        let backupArguments = config.backupArguments(pair)
        busy = true
        statusKey = "restoringBackup"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try restoreSavedBackup(pair, id: id, retentionDays: retentionDays,
                                           backupArguments: backupArguments)
                resultKey = "backupRestored"
                resultDetail = nil
            } catch {
                resultKey = "error"
                resultDetail = uiError(error, language: language)
            }
            DispatchQueue.main.async {
                self.statusKey = resultKey
                self.statusDetail = resultDetail
                self.busy = false
                self.refreshHistory()
                self.refreshConflicts()
            }
        }
    }
}

#if !CLOUD_CONFIG_TESTS
@main
struct ResearchSyncApp: App {
    @StateObject private var model: SyncModel
    @NSApplicationDelegateAdaptor(PathSyncAppDelegate.self) private var appDelegate

    init() {
        let args = CommandLine.arguments
        if args.contains("--install") {
            do {
                let config = try loadConfig()
                try validatedPairSet(config.pairs)
                try validatedBackupLocation(config)
                for pair in config.pairs where pair.enabled {
                    _ = try pendingConflicts(for: pair)
                }
                try saveConfig(config)
                try installSchedule(config)
                print("定时任务已安装：\(agentPath)")
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let resolution = args.firstIndex(of: "--resolve") {
            do {
                guard args.indices.contains(resolution + 1),
                      let choiceIndex = args.firstIndex(of: "--choice"), args.indices.contains(choiceIndex + 1),
                      let pairIndex = args.firstIndex(of: "--pair"), args.indices.contains(pairIndex + 1),
                      let id = UUID(uuidString: args[pairIndex + 1]) else {
                    throw NSError(domain: appID, code: 11, userInfo: [NSLocalizedDescriptionKey: "解决冲突需要 --resolve 路径、--choice local|cloud|both|newest 和 --pair UUID。"])
                }
                let configPath: String
                if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
                else { configPath = defaultConfigPath }
                let config = try loadConfig(configPath)
                guard let pair = config.pairs.first(where: { $0.id == id }) else {
                    throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "找不到指定路径组。"])
                }
                print(try resolvePendingConflict(pair, name: args[resolution + 1],
                                                 choice: args[choiceIndex + 1],
                                                 retentionDays: config.backupRetentionDays,
                                                 backupArguments: config.backupArguments(pair)))
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let review = args.firstIndex(of: "--acknowledge") {
            do {
                guard args.indices.contains(review + 1),
                      let pairIndex = args.firstIndex(of: "--pair"), args.indices.contains(pairIndex + 1),
                      let id = UUID(uuidString: args[pairIndex + 1]) else {
                    throw NSError(domain: appID, code: 11, userInfo: [NSLocalizedDescriptionKey: "确认版本需要 --acknowledge 路径和 --pair UUID。"])
                }
                let configPath: String
                if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
                else { configPath = defaultConfigPath }
                let config = try loadConfig(configPath)
                guard let pair = config.pairs.first(where: { $0.id == id }) else {
                    throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "找不到指定路径组。"])
                }
                print(try acknowledgePreservedConflict(pair, name: args[review + 1],
                                                       backupArguments: config.backupArguments(pair)))
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let selection = args.firstIndex(of: "--review-newest") {
            do {
                guard args.indices.contains(selection + 1),
                      let pairIndex = args.firstIndex(of: "--pair"), args.indices.contains(pairIndex + 1),
                      let id = UUID(uuidString: args[pairIndex + 1]) else {
                    throw NSError(domain: appID, code: 14, userInfo: [NSLocalizedDescriptionKey: "按日期处理保留版本需要 --review-newest 路径和 --pair UUID。"])
                }
                let configPath: String
                if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
                else { configPath = defaultConfigPath }
                let config = try loadConfig(configPath)
                guard let pair = config.pairs.first(where: { $0.id == id }) else {
                    throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "找不到指定路径组。"])
                }
                print(try resolvePreservedNewest(pair, name: args[selection + 1],
                                                 retentionDays: config.backupRetentionDays,
                                                 backupArguments: config.backupArguments(pair)))
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let restoration = args.firstIndex(of: "--restore-backup") {
            do {
                guard args.indices.contains(restoration + 1),
                      let pairIndex = args.firstIndex(of: "--pair"), args.indices.contains(pairIndex + 1),
                      let id = UUID(uuidString: args[pairIndex + 1]) else {
                    throw NSError(domain: appID, code: 13, userInfo: [NSLocalizedDescriptionKey: "恢复备份需要 --restore-backup ID 和 --pair UUID。"])
                }
                let configPath: String
                if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
                else { configPath = defaultConfigPath }
                let config = try loadConfig(configPath)
                guard let pair = config.pairs.first(where: { $0.id == id }) else {
                    throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "找不到指定路径组。"])
                }
                print(try restoreSavedBackup(pair, id: args[restoration + 1],
                                             retentionDays: config.backupRetentionDays,
                                             backupArguments: config.backupArguments(pair)))
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if args.contains("--status") {
            let configPath: String
            if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
            else { configPath = defaultConfigPath }
            do {
                print(syncStatusJSON(try loadConfig(configPath)))
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if args.contains("--sync") || args.contains("--dry-run") || args.contains("--push") || args.contains("--pull") || args.contains("--merge") {
            let configPath: String
            if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
            else { configPath = defaultConfigPath }
            do {
                let config = try loadConfig(configPath)
                let direction: SyncDirection? = args.contains("--merge") ? .merge :
                    (args.contains("--pull") ? .download : (args.contains("--push") ? .upload : nil))
                let id: UUID?
                if let index = args.firstIndex(of: "--pair"), args.indices.contains(index + 1) { id = UUID(uuidString: args[index + 1]) }
                else { id = nil }
                let dryRun = args.contains("--dry-run")
                let output = try runSync(config, pairID: id, direction: direction,
                                         dryRun: dryRun) { _, message in
                    fputs(message + "\n", stderr)
                }
                if !dryRun { postSyncNotification(config: config, output: output, failed: false) }
                print(output)
                exit(0)
            } catch {
                if !args.contains("--dry-run"), let config = try? loadConfig(configPath) {
                    postSyncNotification(config: config, output: "", failed: true)
                }
                fputs(error.localizedDescription + "\n", stderr)
                exit(1)
            }
        }
        let model = SyncModel()
        URLCommandRouter.model = model
        self._model = StateObject(wrappedValue: model)
        UNUserNotificationCenter.current().delegate = syncNotificationDelegate
    }

    var body: some Scene {
        Window("路径同步", id: "main") { ContentView(model: model) }
            .windowStyle(.titleBar)
            .defaultSize(width: 980, height: 680)
        MenuBarExtra {
            MenuBarPanel(model: model)
                .onAppear { model.refreshState() }
        } label: {
            Image(nsImage: menuBarIcon())
                .accessibilityLabel(uiText("appName", language: model.config.language))
        }
        .menuBarExtraStyle(.window)
    }
}
#endif
