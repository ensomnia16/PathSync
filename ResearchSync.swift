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

func backupAvailable(_ pair: SyncPair, id: String) -> Bool {
    guard id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return false }
    let root = URL(fileURLWithPath: mergeStatePath(pair)).deletingPathExtension()
        .path + "-backups/" + id
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

    enum CodingKeys: String, CodingKey {
        case id, name, localPath, cloudPath, scheduledDirection, enabled
        case syncCodexFiles, syncClaudeFiles, syncTemporaryFiles
    }

    init(id: UUID = UUID(), name: String = "新路径", localPath: String = "", cloudPath: String = "",
         scheduledDirection: String = "merge", enabled: Bool = false,
         syncCodexFiles: Bool = true, syncClaudeFiles: Bool = true, syncTemporaryFiles: Bool = false) {
        self.id = id
        self.name = name
        self.localPath = localPath
        self.cloudPath = cloudPath
        self.scheduledDirection = scheduledDirection
        self.enabled = enabled
        self.syncCodexFiles = syncCodexFiles
        self.syncClaudeFiles = syncClaudeFiles
        self.syncTemporaryFiles = syncTemporaryFiles
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

    enum CodingKeys: String, CodingKey {
        case pairs, intervalHours, nightlyAt23, scheduleMode, dailyHour, dailyMinute
        case excludeLatexIntermediates, conflictPolicy, backupRetentionDays, enabled, language, notificationMode
        case checkForUpdates, autoInstallUpdates, cloudConfigEnabled, oneDriveRoot, localRoot, cloudImportAnchors
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

func pendingConflicts(for pair: SyncPair) throws -> [PendingConflict] {
    let path = mergeStatePath(pair)
    guard fm.fileExists(atPath: path) else { return [] }
    let state = try JSONDecoder().decode(ConflictState.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let local = URL(fileURLWithPath: pair.localPath).standardizedFileURL.resolvingSymlinksInPath().path
    let cloud = URL(fileURLWithPath: pair.cloudPath).standardizedFileURL.resolvingSymlinksInPath().path
    guard state.local == local, state.cloud == cloud else {
        throw NSError(domain: appID, code: 10, userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」的路径与冲突记录不一致。请检查路径配置。"])
    }
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

func appendLog(_ message: String) {
    try? fm.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if !fm.fileExists(atPath: logPath) { fm.createFile(atPath: logPath, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
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
                     language: String, progress: ((String) -> Void)?) throws -> String {
    let (local, cloud) = try validatedPaths(pair)
    let (source, destination) = direction == .download ? (cloud, local) : (local, cloud)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
    var arguments = [helper, local, cloud, mergeStatePath(pair), "--direction", direction.rawValue,
                     "--conflict-policy", conflictPolicy,
                     "--backup-retention-days", String(backupRetentionDays)]
    if excludeLatex { arguments.append("--exclude-latex") }
    if !pair.syncCodexFiles { arguments.append("--skip-codex") }
    if !pair.syncClaudeFiles { arguments.append("--skip-claude") }
    if pair.syncTemporaryFiles { arguments.append("--include-temp") }
    if dryRun { arguments.append("--dry-run") }
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
                progress(String(format: uiText("scanProgress", language: language),
                                pair.name, side, String(fields[3]), String(fields[4])))
            } else if fields.count == 4, fields[1] == "PROCESS" {
                progress(String(format: uiText("processProgress", language: language),
                                pair.name, String(fields[2]), String(fields[3])))
            } else if fields.count == 4, fields[1] == "PREFETCH" {
                progress(String(format: uiText("prefetchProgress", language: language),
                                pair.name, String(fields[2]), String(fields[3])))
            } else if fields.count >= 3, fields[1] == "FILE" {
                progress(String(format: uiText("fileProgress", language: language),
                                pair.name, fields.dropFirst(2).joined(separator: "\t")))
            }
        }
    }
    let result = String(decoding: collected, as: UTF8.self)
        .components(separatedBy: "\n")
        .filter { !$0.hasPrefix("PROGRESS\t") }
        .joined(separator: "\n")
    process.waitUntilExit()
    appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
    activityLock.lock()
    let stalled = inactivityTimedOut
    activityLock.unlock()
    if stalled {
        throw NSError(domain: appID, code: 15, userInfo: [NSLocalizedDescriptionKey:
            "「\(pair.name)」连续 3 分钟未收到 OneDrive 文件系统响应，已停止本次运行；其他路径继续同步。"])
    }
    guard process.terminationStatus == 0 else {
        let summary = result.split(separator: "\n").last.map(String.init) ?? "退出码 \(process.terminationStatus)"
        throw NSError(domain: appID, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」未完全成功：\(summary)。详情见同步记录。"])
    }
    return result
}

func resolvePendingConflict(_ pair: SyncPair, name: String, choice: String,
                            retentionDays: Int = 15) throws -> String {
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

func acknowledgePreservedConflict(_ pair: SyncPair, name: String) throws -> String {
    try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--acknowledge", name]
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

func resolvePreservedNewest(_ pair: SyncPair, name: String, retentionDays: Int) throws -> String {
    try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--review-newest", name,
                             "--backup-retention-days", String(retentionDays)]
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

func restoreSavedBackup(_ pair: SyncPair, id: String, retentionDays: Int) throws -> String {
    try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--restore", id,
                             "--backup-retention-days", String(retentionDays)]
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

@discardableResult
func runSync(_ config: SyncConfig, pairID: UUID? = nil, direction: SyncDirection? = nil,
             dryRun: Bool = false, progress: ((String) -> Void)? = nil) throws -> String {
    let selected = config.pairs.filter { pairID == nil ? $0.enabled : $0.id == pairID }
    guard !selected.isEmpty else {
        throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "没有可同步的路径。"])
    }
    return try withSyncLock {
        try validatedPairSet(config.pairs, including: pairID)
        var outputs: [String] = []
        var errors: [String] = []
        for pair in selected {
            do {
                let chosen = direction ?? SyncDirection(rawValue: pair.scheduledDirection) ?? .upload
                let result = try syncOne(pair, direction: chosen,
                                         excludeLatex: config.excludeLatexIntermediates,
                                         conflictPolicy: config.conflictPolicy,
                                         backupRetentionDays: config.backupRetentionDays,
                                         dryRun: dryRun, language: config.language, progress: progress)
                outputs.append("[\(pair.name)] \(result)")
            } catch {
                errors.append(error.localizedDescription)
                appendLog("失败 [\(pair.name)]：\(error.localizedDescription)")
            }
        }
        if !errors.isEmpty {
            throw NSError(domain: appID, code: 8, userInfo: [NSLocalizedDescriptionKey: "\(selected.count - errors.count)/\(selected.count) 组完成；\(errors.joined(separator: "；"))"])
        }
        return outputs.joined(separator: "\n")
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

    func refreshHistory() {
        do {
            history = try readSyncHistory(at: logPath).filter { record in
                config.pairs.contains { pair in
                    (record.sourcePath == pair.localPath && record.destinationPath == pair.cloudPath)
                    || (record.sourcePath == pair.cloudPath && record.destinationPath == pair.localPath)
                }
            }
            historyError = nil
        } catch {
            historyError = uiError(error, language: config.language)
        }
    }

    func refreshConflicts() {
        var updated: [UUID: [PendingConflict]] = [:]
        for pair in config.pairs {
            do { updated[pair.id] = try pendingConflicts(for: pair) }
            catch {
                statusKey = "error"
                statusDetail = uiError(error, language: config.language)
            }
        }
        conflictsByPair = updated
        if statusKey == "ready" || statusKey == "conflictsPending" {
            statusKey = conflictCount > 0 ? "conflictsPending" : "ready"
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
            try installSchedule(config)
            statusKey = config.enabled ? "savedEnabled" : "savedDisabled"
            statusDetail = nil
            refreshConflicts()
            if config.cloudConfigEnabled { publishCloudConfig(config) }
            if config.autoInstallUpdates { installAvailableUpdate() }
        } catch { statusKey = "error"; statusDetail = uiError(error, language: config.language) }
    }

    func syncNow(_ direction: SyncDirection? = nil, all: Bool = false) {
        guard !hasUnsavedChanges, all || selectedID != nil else { return }
        busy = true
        statusKey = all ? "syncingAll" : "syncingPair"
        statusDetail = nil
        let current = config
        let id = all ? nil : selectedID
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                let output = try runSync(current, pairID: id, direction: direction) { message in
                    DispatchQueue.main.async { self.statusDetail = message }
                }
                postSyncNotification(config: current, output: output, failed: false)
                let reviews = output.components(separatedBy: "reviews=").dropFirst()
                    .compactMap { Int($0.prefix(while: \.isNumber)) }.reduce(0, +)
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
                self.busy = false
                self.refreshConflicts()
                self.refreshHistory()
                if self.config.autoInstallUpdates { self.installAvailableUpdate() }
            }
        }
    }

    func resolveConflict(_ name: String, choice: String) {
        guard let pair = selectedPair, !busy, !hasUnsavedChanges else { return }
        let language = config.language
        let retentionDays = config.backupRetentionDays
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try resolvePendingConflict(pair, name: name, choice: choice,
                                               retentionDays: retentionDays)
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

    func acknowledgeConflict(_ name: String) {
        guard let pair = selectedPair, !busy else { return }
        let language = config.language
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try acknowledgePreservedConflict(pair, name: name)
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

    func chooseNewestForReview(_ name: String) {
        guard let pair = selectedPair, !busy else { return }
        let language = config.language
        let retentionDays = config.backupRetentionDays
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try resolvePreservedNewest(pair, name: name, retentionDays: retentionDays)
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
        busy = true
        statusKey = "restoringBackup"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try restoreSavedBackup(pair, id: id, retentionDays: retentionDays)
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

    init() {
        let args = CommandLine.arguments
        if args.contains("--install") {
            do {
                let config = try loadConfig()
                try validatedPairSet(config.pairs)
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
                                                 retentionDays: config.backupRetentionDays))
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
                print(try acknowledgePreservedConflict(pair, name: args[review + 1]))
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
                                                 retentionDays: config.backupRetentionDays))
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
                                             retentionDays: config.backupRetentionDays))
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
                                         dryRun: dryRun) { message in
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
        self._model = StateObject(wrappedValue: SyncModel())
        UNUserNotificationCenter.current().delegate = syncNotificationDelegate
    }

    var body: some Scene {
        Window("路径同步", id: "main") { ContentView(model: model) }
            .windowStyle(.titleBar)
            .defaultSize(width: 980, height: 680)
        MenuBarExtra {
            MenuBarContent(model: model)
                .onAppear {
                    model.refreshConflicts()
                    model.refreshHistory()
                }
                .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
                    model.refreshConflicts()
                    model.refreshHistory()
                    model.checkForUpdates(automatic: true)
                }
        } label: {
            Image(nsImage: menuBarIcon())
                .accessibilityLabel(uiText("appName", language: model.config.language))
        }
        .menuBarExtraStyle(.menu)
    }
}
#endif
