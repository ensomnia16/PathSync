import AppKit
import Foundation
import SwiftUI

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

struct SyncPair: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "新路径"
    var localPath: String = ""
    var cloudPath: String = ""
    var scheduledDirection: String = "merge"
    var enabled: Bool = false
}

struct SyncConfig: Codable {
    var pairs: [SyncPair] = [SyncPair()]
    var intervalHours = 24
    var scheduleMode = "daily"
    var dailyHour = 23
    var dailyMinute = 0
    var excludeLatexIntermediates = true
    var conflictPolicy = "keep-both"
    var enabled = true
    var language = "zh-Hans"

    enum CodingKeys: String, CodingKey {
        case pairs, intervalHours, nightlyAt23, scheduleMode, dailyHour, dailyMinute
        case excludeLatexIntermediates, conflictPolicy, enabled, language
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
        enabled = try data.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        language = try data.decodeIfPresent(String.self, forKey: .language) ?? "zh-Hans"
        if let saved = try data.decodeIfPresent([SyncPair].self, forKey: .pairs) {
            pairs = saved
        } else {
            let local = try data.decodeIfPresent(String.self, forKey: .source) ?? ""
            let cloud = try data.decodeIfPresent(String.self, forKey: .destination) ?? ""
            let direction = try data.decodeIfPresent(String.self, forKey: .scheduledDirection) ?? "upload"
            pairs = [SyncPair(name: "已导入路径", localPath: local, cloudPath: cloud,
                              scheduledDirection: direction, enabled: !local.isEmpty && !cloud.isEmpty)]
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
        try data.encode(enabled, forKey: .enabled)
        try data.encode(language, forKey: .language)
    }
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

func saveConfig(_ config: SyncConfig) throws {
    try fm.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(config).write(to: URL(fileURLWithPath: defaultConfigPath), options: .atomic)
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

struct PendingConflict: Identifiable {
    let name: String
    let localBytes: Int64
    let cloudBytes: Int64
    var id: String { name }
}

private struct StoredConflict: Decodable {
    let local: [Int64]
    let cloud: [Int64]
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
    return (state.conflicts ?? [:]).map { name, record in
        PendingConflict(name: name, localBytes: record.local.first ?? 0,
                        cloudBytes: record.cloud.first ?? 0)
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
                     conflictPolicy: String, dryRun: Bool) throws -> String {
    let (local, cloud) = try validatedPaths(pair)
    let (source, destination) = direction == .download ? (cloud, local) : (local, cloud)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
    var arguments = [helper, local, cloud, mergeStatePath(pair), "--direction", direction.rawValue,
                     "--conflict-policy", conflictPolicy]
    if excludeLatex { arguments.append("--exclude-latex") }
    if dryRun { arguments.append("--dry-run") }
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    appendLog("\(dryRun ? "预览" : "开始") [\(pair.name)] \(direction.label)：\(source) → \(destination)")
    try process.run()
    let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    appendLog("结束 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
    guard process.terminationStatus == 0 else {
        let summary = result.split(separator: "\n").last.map(String.init) ?? "退出码 \(process.terminationStatus)"
        throw NSError(domain: appID, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」未完全成功：\(summary)。详情见同步记录。"])
    }
    return result
}

func resolvePendingConflict(_ pair: SyncPair, name: String, choice: String) throws -> String {
    guard ["local", "cloud", "both"].contains(choice) else {
        throw NSError(domain: appID, code: 11, userInfo: [NSLocalizedDescriptionKey: "无效的冲突处理方式。"])
    }
    return try withSyncLock {
        let (local, cloud) = try validatedPaths(pair)
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_merge.py").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper, local, cloud, mergeStatePath(pair), "--resolve", name, "--choice", choice]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        appendLog("解决冲突 [\(pair.name)] \(name)：\(choice)")
        try process.run()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        appendLog("冲突处理 [\(pair.name)]，退出码 \(process.terminationStatus)：\(result.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard process.terminationStatus == 0 else {
            throw NSError(domain: appID, code: 12, userInfo: [NSLocalizedDescriptionKey: "「\(name)」处理失败：\(result.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        return result
    }
}

@discardableResult
func runSync(_ config: SyncConfig, pairID: UUID? = nil, direction: SyncDirection? = nil, dryRun: Bool = false) throws -> String {
    let selected = config.pairs.filter { pairID == nil ? $0.enabled : $0.id == pairID }
    guard !selected.isEmpty else {
        throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "没有可同步的路径。"])
    }
    return try withSyncLock {
        var outputs: [String] = []
        var errors: [String] = []
        for pair in selected {
            do {
                let chosen = direction ?? SyncDirection(rawValue: pair.scheduledDirection) ?? .upload
                let result = try syncOne(pair, direction: chosen,
                                         excludeLatex: config.excludeLatexIntermediates,
                                         conflictPolicy: config.conflictPolicy, dryRun: dryRun)
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
    @Published var selectedID: UUID?
    @Published var page = "schedule"
    @Published var statusKey = "ready"
    @Published var statusDetail: String?
    @Published var busy = false
    @Published var conflictsByPair: [UUID: [PendingConflict]] = [:]
    @Published var history: [SyncHistoryRecord] = []
    @Published var historyError: String?

    init() {
        config = (try? loadConfig()) ?? SyncConfig()
        selectedID = config.pairs.first?.id
        refreshConflicts()
        refreshHistory()
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
        page = selectedID == nil ? "schedule" : "pair"
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

    func save() {
        do {
            if config.enabled && !config.pairs.contains(where: { $0.enabled }) {
                throw NSError(domain: appID, code: 9, userInfo: [NSLocalizedDescriptionKey: "启用后台同步前，请至少启用一组路径。"])
            }
            for pair in config.pairs where pair.enabled {
                _ = try validatedPaths(pair)
                _ = try pendingConflicts(for: pair)
            }
            config.intervalHours = min(168, max(6, config.intervalHours))
            config.dailyHour = min(23, max(0, config.dailyHour))
            config.dailyMinute = min(59, max(0, config.dailyMinute))
            if !["keep-both", "ask"].contains(config.conflictPolicy) {
                config.conflictPolicy = "keep-both"
            }
            try saveConfig(config)
            try installSchedule(config)
            statusKey = config.enabled ? "savedEnabled" : "savedDisabled"
            statusDetail = nil
            refreshConflicts()
        } catch { statusKey = "error"; statusDetail = uiError(error, language: config.language) }
    }

    func syncNow(_ direction: SyncDirection? = nil, all: Bool = false) {
        guard all || selectedID != nil else { return }
        busy = true
        statusKey = all ? "syncingAll" : "syncingPair"
        statusDetail = nil
        let current = config
        let id = all ? nil : selectedID
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                let output = try runSync(current, pairID: id, direction: direction)
                let kept = output.split(separator: "\n").filter { $0.contains("KEPT_BOTH\t") }.count
                resultKey = all ? "doneAll" : "donePair"
                resultDetail = kept > 0
                    ? String(format: uiText("keptBothResult", language: current.language), kept)
                    : nil
            } catch { resultKey = "error"; resultDetail = uiError(error, language: current.language) }
            DispatchQueue.main.async {
                self.statusKey = resultKey
                self.statusDetail = resultDetail
                self.busy = false
                self.refreshConflicts()
                self.refreshHistory()
            }
        }
    }

    func resolveConflict(_ name: String, choice: String) {
        guard let pair = selectedPair, !busy else { return }
        let language = config.language
        busy = true
        statusKey = "resolving"
        statusDetail = nil
        DispatchQueue.global(qos: .utility).async {
            let resultKey: String
            let resultDetail: String?
            do {
                _ = try resolvePendingConflict(pair, name: name, choice: choice)
                resultKey = "resolved"
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
}

@main
struct ResearchSyncApp: App {
    init() {
        let args = CommandLine.arguments
        if args.contains("--install") {
            do {
                let config = try loadConfig()
                for pair in config.pairs where pair.enabled {
                    _ = try validatedPaths(pair)
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
                    throw NSError(domain: appID, code: 11, userInfo: [NSLocalizedDescriptionKey: "解决冲突需要 --resolve 路径、--choice local|cloud|both 和 --pair UUID。"])
                }
                let configPath: String
                if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
                else { configPath = defaultConfigPath }
                let config = try loadConfig(configPath)
                guard let pair = config.pairs.first(where: { $0.id == id }) else {
                    throw NSError(domain: appID, code: 7, userInfo: [NSLocalizedDescriptionKey: "找不到指定路径组。"])
                }
                print(try resolvePendingConflict(pair, name: args[resolution + 1], choice: args[choiceIndex + 1]))
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
                print(try runSync(config, pairID: id, direction: direction, dryRun: args.contains("--dry-run")))
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.titleBar)
    }
}
