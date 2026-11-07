import SwiftUI

// Select the property wrapper on SDKs that also expose a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct StorageUsage: Decodable {
    let localBytes: Int64
    let cloudBytes: Int64
    let verifiedBytes: Int64
    let differentBytes: Int64
    let unverifiedBytes: Int64
    let errors: Int
}

private struct StorageRow: Decodable, Identifiable {
    let path: String
    let isDirectory: Bool
    let hasCloud: Bool
    let selectable: Bool
    let usage: StorageUsage

    var id: String { path }
}

private struct StorageReport: Decodable {
    let rows: [StorageRow]
    let totals: StorageUsage
}

struct StorageAnalysisView: View {
    @ObservedObject var model: SyncModel
    let pairID: UUID

    @Environment(\.dismiss) private var dismiss
    @ViewState private var scope: String = ""
    @ViewState private var query: String = ""
    @ViewState private var selection: Set<String> = []
    @ViewState private var report: StorageReport? = nil
    @ViewState private var process: Process? = nil
    @ViewState private var error: String? = nil

    private var pair: SyncPair? { model.config.pairs.first { $0.id == pairID } }

    private func t(_ zh: String, _ en: String) -> String {
        model.config.language == "en" ? en : zh
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func description(_ usage: StorageUsage) -> String {
        [
            t("工作副本", "Working copy") + " " + bytes(usage.localBytes),
            t("OneDrive 本机缓存", "OneDrive cache on this Mac") + " " + bytes(usage.cloudBytes),
            t("内容相同", "Content matched") + " " + bytes(usage.verifiedBytes),
            t("候选未验证", "Unverified candidates") + " " + bytes(usage.unverifiedBytes),
            t("无对应文件或内容不同", "Missing or different") + " " + bytes(usage.differentBytes)
        ].joined(separator: "  ·  ")
    }

    private func isCovered(_ row: StorageRow) -> Bool {
        let others = (pair?.cloudOnlyPaths ?? []) + selection.filter { $0 != row.path }
        return others.contains {
            row.path == $0 || row.path.hasPrefix($0 + "/") || $0.hasPrefix(row.path + "/")
        }
    }

    private func alreadyConfigured(_ path: String) -> Bool {
        (pair?.cloudOnlyPaths ?? []).contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func coverageNote(_ row: StorageRow) -> String? {
        if pair?.cloudOnlyPaths.contains(row.path) == true {
            return t("已设为仅云端", "Already Set to Cloud Only")
        }
        if alreadyConfigured(row.path) {
            return t("父目录已设为仅云端", "Parent Folder Is Set to Cloud Only")
        }
        if (pair?.cloudOnlyPaths ?? []).contains(where: { $0.hasPrefix(row.path + "/") }) {
            return t("包含已设为仅云端的子目录，请在主页面调整", "Contains a cloud-only subfolder. Manage it on the folder page.")
        }
        if isCovered(row) {
            return t("与本次已选的父目录或子目录重叠", "Overlaps a selected parent or subfolder")
        }
        return nil
    }

    private func scan(_ folder: String, verify: Bool = false) {
        guard process == nil, let pair, let resources = Bundle.main.resourceURL else { return }
        if scope != folder { query = "" }
        scope = folder
        report = nil
        error = nil

        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        job.arguments = ["-B", resources.appendingPathComponent("storage_analysis.py").path,
                         "--scope=" + folder, "--", pair.localPath, pair.cloudPath]
        if verify { job.arguments?.insert("--verify", at: 2) }
        let output = Pipe()
        job.standardOutput = output
        job.standardError = output
        do {
            try job.run()
            process = job
        } catch {
            self.error = error.localizedDescription
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            job.waitUntilExit()
            let result = job.terminationStatus == 0 ? try? JSONDecoder().decode(StorageReport.self, from: data) : nil
            DispatchQueue.main.async {
                guard process === job else { return }
                process = nil
                report = result
                if result == nil {
                    error = job.terminationStatus == 0
                        ? t("无法读取分析结果。", "Could not read the analysis report.")
                        : String(decoding: data, as: UTF8.self)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("本地空间分析", "Local Storage Analysis")).font(.title2.bold())
            Text(t("按磁盘实际分配统计。同路径、同大小只是候选；内容校验读取已下载的文件。",
                   "Counts allocated disk space. Same path and size indicate a candidate. Verification reads files already downloaded."))
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    scan(scope.split(separator: "/").dropLast().joined(separator: "/"))
                } label: {
                    Label(t("上一级", "Parent Folder"), systemImage: "arrow.up")
                }
                .disabled(scope.isEmpty || process != nil)
                Text(scope.isEmpty ? pair?.name ?? "" : scope)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                if let process {
                    ProgressView().controlSize(.small)
                    Button(t("停止分析", "Stop Analysis")) {
                        self.process = nil
                        if process.isRunning { process.terminate() }
                    }
                } else {
                    Button(t("扫描占用", "Scan Usage")) { scan(scope) }
                    Button(t("校验重复内容", "Verify Matching Content")) { scan(scope, verify: true) }
                }
            }
            TextField(t("筛选当前列表", "Filter This List"), text: $query)
                .textFieldStyle(.roundedBorder)
            if let report {
                Text(description(report.totals)).font(.caption).foregroundStyle(.secondary)
                if report.totals.errors > 0 {
                    Text(t("有 \(report.totals.errors) 项未能完整检查，部分占用可能未计入。",
                           "\(report.totals.errors) entries could not be checked completely. Some usage may be missing."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List {
                ForEach((report?.rows ?? []).filter { query.isEmpty || $0.path.localizedStandardContains(query) }) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle(isOn: Binding(get: { alreadyConfigured(row.path) || selection.contains(row.path) }, set: { chosen in
                            if chosen { selection.insert(row.path) } else { selection.remove(row.path) }
                        })) {
                            Text(row.path)
                        }
                        .labelsHidden()
                        .accessibilityLabel(row.path)
                        .toggleStyle(.checkbox)
                        .disabled(!row.selectable || isCovered(row))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.path.split(separator: "/").last.map(String.init) ?? row.path)
                            if let note = coverageNote(row) {
                                Label(note, systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(description(row.usage)).font(.caption).foregroundStyle(.secondary)
                            if !row.hasCloud {
                                Text(t("未找到 OneDrive 对应项", "No matching OneDrive item"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if row.isDirectory {
                            Button {
                                scan(row.path)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(t("浏览 " + row.path, "Browse " + row.path))
                            .disabled(process != nil || (try? normalizeCloudOnlyPath(row.path)) == nil)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            HStack {
                Text(t("本次新选 \(selection.count) 项", "\(selection.count) newly selected"))
                    .foregroundStyle(.secondary)
                Button(t("清空选择", "Clear Selection")) { selection.removeAll() }
                    .disabled(selection.isEmpty)
                Spacer()
                Button(t("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("加入仅云端", "Add to Cloud Only")) {
                    model.addCloudOnlyPaths(Array(selection), pairID: pairID)
                    if model.statusKey == "cloudOnlyAdded" {
                        dismiss()
                    } else {
                        error = model.statusDetail
                    }
                }
                .disabled(selection.isEmpty || model.isSyncActive)
            }
        }
        .padding(20)
        .frame(minWidth: 800, minHeight: 500)
        .onAppear { scan("") }
        .onDisappear {
            if let process, process.isRunning { process.terminate() }
            process = nil
        }
    }
}
