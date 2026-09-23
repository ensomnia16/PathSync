import AppKit
import Foundation
import SwiftUI

private let appID = "com.ensom.ResearchSync"
private let fm = FileManager.default
private let home = fm.homeDirectoryForCurrentUser.path
private let supportDirectory = home + "/Library/Application Support/ResearchSync"
private let defaultConfigPath = supportDirectory + "/config.json"
private let logPath = supportDirectory + "/sync.log"
private let agentPath = home + "/Library/LaunchAgents/" + appID + ".plist"

struct SyncPair: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "新路径"
    var localPath: String = ""
    var cloudPath: String = ""
    var scheduledDirection: String = "upload"
    var enabled: Bool = false
}

struct SyncConfig: Codable {
    var pairs: [SyncPair] = [SyncPair()]
    var intervalHours = 24
    var nightlyAt23 = true
    var excludeLatexIntermediates = true
    var enabled = true

    enum CodingKeys: String, CodingKey {
        case pairs, intervalHours, nightlyAt23, excludeLatexIntermediates, enabled
        case source, destination, scheduledDirection
    }

    init() {}

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        intervalHours = try data.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 24
        nightlyAt23 = try data.decodeIfPresent(Bool.self, forKey: .nightlyAt23) ?? true
        excludeLatexIntermediates = try data.decodeIfPresent(Bool.self, forKey: .excludeLatexIntermediates) ?? true
        enabled = try data.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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
        try data.encode(nightlyAt23, forKey: .nightlyAt23)
        try data.encode(excludeLatexIntermediates, forKey: .excludeLatexIntermediates)
        try data.encode(enabled, forKey: .enabled)
    }
}

enum SyncDirection: String {
    case upload, download
    var label: String { self == .upload ? "本地 → 云端" : "云端 → 本地" }
}

private let latexExcludes = [
    "*.aux", "*.log", "*.synctex.gz", "*.fls", "*.fdb_latexmk", "*.out",
    "*.toc", "*.lof", "*.lot", "*.blg", "*.bcf", "*.run.xml",
    "*.nav", "*.snm", "*.vrb", "*.xdv", "*.acn", "*.acr", "*.alg",
    "*.glg", "*.glo", "*.ist", "*.ilg", "*.idx", "_minted-*/",
    "*.synctex(busy)", ".DS_Store"
]

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

private func syncOne(_ pair: SyncPair, direction: SyncDirection, excludeLatex: Bool, dryRun: Bool) throws -> String {
    let (local, cloud) = try validatedPaths(pair)
    let (source, destination) = direction == .upload ? (local, cloud) : (cloud, local)
    let process = Process()
    if direction == .download {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let helper = (Bundle.main.resourceURL ?? URL(fileURLWithPath: supportDirectory)).appendingPathComponent("sync_tree.py").path
        var arguments = [helper, source, destination]
        if excludeLatex { arguments.append("--exclude-latex") }
        if dryRun { arguments.append("--dry-run") }
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        var arguments = ["-a", "--update", "--stats", "--timeout=120"]
        for pattern in ["*.researchsync-partial", ".venv/", "__pycache__/", "pycache/", "*.pyc", "node_modules/", ".pytest_cache/", ".mypy_cache/", ".ruff_cache/"] {
            arguments += ["--exclude", pattern]
        }
        if dryRun { arguments.append("--dry-run") }
        if excludeLatex { for pattern in latexExcludes { arguments += ["--exclude", pattern] } }
        arguments += [source + "/", destination + "/"]
        process.arguments = arguments
    }
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
        throw NSError(domain: appID, code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "「\(pair.name)」未完全成功：\(summary)。详情见日志。"])
    }
    return result
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
                outputs.append("[\(pair.name)] \(try syncOne(pair, direction: chosen, excludeLatex: config.excludeLatexIntermediates, dryRun: dryRun))")
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
    if config.nightlyAt23 && config.intervalHours == 24 {
        plist["StartCalendarInterval"] = ["Hour": 23, "Minute": 0]
    } else { plist["StartInterval"] = max(6, config.intervalHours) * 3600 }
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
    @Published var status = "准备就绪"
    @Published var busy = false

    init() {
        config = (try? loadConfig()) ?? SyncConfig()
        selectedID = config.pairs.first?.id
    }

    var selectedIndex: Int? { config.pairs.firstIndex { $0.id == selectedID } }
    var selectedPair: SyncPair? { selectedIndex.map { config.pairs[$0] } }

    func addPair() {
        let pair = SyncPair()
        config.pairs.append(pair)
        selectedID = pair.id
        status = "选择这组路径的本地和云端文件夹，启用后保存。"
    }

    func removeSelected() {
        guard let index = selectedIndex else { return }
        config.pairs.remove(at: index)
        selectedID = config.pairs.first?.id
        status = "路径已从列表移除；点击“保存设置”后生效。"
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
        }
    }

    func save() {
        do {
            if config.enabled && !config.pairs.contains(where: { $0.enabled }) {
                throw NSError(domain: appID, code: 9, userInfo: [NSLocalizedDescriptionKey: "启用后台同步前，请至少启用一组路径。"])
            }
            for pair in config.pairs where pair.enabled { _ = try validatedPaths(pair) }
            config.intervalHours = min(168, max(6, config.intervalHours))
            try saveConfig(config)
            try installSchedule(config)
            status = config.enabled ? "已保存 · 定时同步已启用" : "已保存 · 定时同步已关闭"
        } catch { status = error.localizedDescription }
    }

    func syncNow(_ direction: SyncDirection? = nil, all: Bool = false) {
        guard all || selectedID != nil else { return }
        busy = true
        status = all ? "正在同步所有已启用路径…" : "正在同步所选路径…"
        let current = config
        let id = all ? nil : selectedID
        DispatchQueue.global(qos: .utility).async {
            let result: String
            do {
                _ = try runSync(current, pairID: id, direction: direction)
                result = all ? "所有已启用路径同步完成。" : "所选路径同步完成。"
            } catch { result = error.localizedDescription }
            DispatchQueue.main.async {
                self.status = result
                self.busy = false
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = SyncModel()
    private let navy = Color(red: 0.08, green: 0.15, blue: 0.29)
    private let blue = Color(red: 0.23, green: 0.43, blue: 0.77)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 258)
            Rectangle().fill(Color.black.opacity(0.09)).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 610)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(LinearGradient(colors: [blue, navy], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("路径同步").font(.system(size: 19, weight: .bold))
                    Text("PATH  ↔  PATH").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.1).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 27).padding(.bottom, 28)

            HStack {
                Text("同步路径").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).tracking(1)
                Spacer()
                Text("\(model.config.pairs.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 21).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.config.pairs) { pair in
                        Button { model.selectedID = pair.id } label: {
                            HStack(spacing: 11) {
                                Image(systemName: pair.enabled ? "folder.fill" : "folder")
                                    .font(.system(size: 16)).foregroundStyle(pair.enabled ? blue : .gray)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pair.name.isEmpty ? "未命名路径" : pair.name)
                                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(pair.enabled ? (pair.scheduledDirection == "download" ? "云端 → 本地" : "本地 → 云端") : "未启用")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if pair.enabled { Circle().fill(Color.green).frame(width: 6, height: 6) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .background(model.selectedID == pair.id ? blue.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }

            VStack(spacing: 8) {
                Button { model.addPair() } label: {
                    Label("添加路径", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(10)
                Button { model.removeSelected() } label: {
                    Label("移除所选", systemImage: "minus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(10)
                .disabled(model.selectedID == nil)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("同步设置").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("多路径管理、定时执行与手动双向同步。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看日志") { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                    .font(.system(size: 12))
            }
            .padding(.bottom, 20)

            if let index = model.selectedIndex {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        pairCard(index)
                        scheduleCard
                        actionCard
                    }
                    .padding(.bottom, 8)
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 35)).foregroundStyle(.secondary)
                    Text("还没有同步路径").font(.headline)
                    Text("点击左侧“添加路径”开始设置。").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
            HStack(spacing: 10) {
                Image(systemName: model.busy ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .foregroundStyle(model.busy ? blue : .green)
                Text(model.status).font(.system(size: 12)).lineLimit(2)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 19)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.055)))
    }

    private func pairCard(_ index: Int) -> some View {
        card {
            HStack {
                Label("路径配置", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("启用此路径", isOn: $model.config.pairs[index].enabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Text("名称").frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
                TextField("例如：论文项目", text: $model.config.pairs[index].name)
                    .textFieldStyle(.roundedBorder)
            }
            pathRow("本地", path: $model.config.pairs[index].localPath) { model.chooseFolder(local: true) }
            pathRow("云端", path: $model.config.pairs[index].cloudPath) { model.chooseFolder(local: false) }
            HStack(spacing: 10) {
                Text("定时方向").foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.config.pairs[index].scheduledDirection) {
                    Text("本地 → 云端").tag("upload")
                    Text("云端 → 本地").tag("download")
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 252)
            }
            .font(.system(size: 12))
        }
    }

    private func pathRow(_ title: String, path: Binding<String>, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 54, alignment: .leading).foregroundStyle(.secondary)
            TextField("选择\(title)文件夹", text: path).textFieldStyle(.roundedBorder)
            Button("选择…", action: choose)
        }
        .font(.system(size: 12))
    }

    private var scheduleCard: some View {
        card {
            Label("定时与过滤", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Text("每隔").foregroundStyle(.secondary)
                TextField("小时", value: $model.config.intervalHours, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 54)
                Text("小时").foregroundStyle(.secondary)
                Spacer()
                Toggle("每天 23:00", isOn: $model.config.nightlyAt23)
                    .disabled(model.config.intervalHours != 24)
            }
            HStack {
                Toggle("排除 LaTeX 中间文件", isOn: $model.config.excludeLatexIntermediates)
                Spacer()
                Toggle("启用后台同步", isOn: $model.config.enabled)
            }
            Text("至少间隔 6 小时 · 不删除文件 · 跳过虚拟环境和缓存")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private var actionCard: some View {
        card {
            Label("立即执行", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 10) {
                Button { model.syncNow(.upload) } label: { Label("本地 → 云端", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent).tint(blue)
                Button { model.syncNow(.download) } label: { Label("云端 → 本地", systemImage: "arrow.down") }
                    .buttonStyle(.bordered)
                Button("同步所有已启用路径") { model.syncNow(all: true) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("保存设置") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .disabled(model.busy)
            Text("两个方向均为单向复制；以较新的文件为准，不自动清理目标端。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

@main
struct ResearchSyncApp: App {
    init() {
        let args = CommandLine.arguments
        if args.contains("--install") {
            do {
                let config = try loadConfig()
                for pair in config.pairs where pair.enabled { _ = try validatedPaths(pair) }
                try saveConfig(config)
                try installSchedule(config)
                print("定时任务已安装：\(agentPath)")
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if args.contains("--sync") || args.contains("--dry-run") || args.contains("--push") || args.contains("--pull") {
            let configPath: String
            if let index = args.firstIndex(of: "--config"), args.indices.contains(index + 1) { configPath = args[index + 1] }
            else { configPath = defaultConfigPath }
            do {
                let config = try loadConfig(configPath)
                let direction: SyncDirection? = args.contains("--pull") ? .download : (args.contains("--push") ? .upload : nil)
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
