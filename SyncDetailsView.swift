import AppKit
import SwiftUI

private final class SyncDetailState: ObservableObject {
    @Published var selection: UUID?
    @Published var query = ""
    @Published var confirmingPause = false
    @Published var pauseFolder = ""
}

/// Activity and file issues shown inside the main overview.
struct SyncDetailsView: View {
    @ObservedObject var model: SyncModel
    @StateObject private var state = SyncDetailState()
    private var english: Bool { usesEnglish(model.config.language) }
    private var pairs: [SyncPair] { model.savedConfig.pairs.filter(\.enabled) }
    private var selected: SyncPair? { pairs.first { $0.id == state.selection } ?? pairs.first }
    private var canChangePolicy: Bool { !model.isSyncActive && !model.hasUnsavedChanges }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pair = selected {
                HStack {
                    Picker(model.t("folders"), selection: Binding(
                        get: { selected?.id }, set: { state.selection = $0 }
                    )) {
                        ForEach(pairs) { item in Text(model.displayName(item)).tag(Optional(item.id)) }
                    }
                    .labelsHidden()
                    .accessibilityLabel(model.t("folders"))
                    Spacer()
                    Button { model.refreshHistory() } label: {
                        Label(model.t("refreshHistory"), systemImage: "arrow.clockwise")
                    }
                }
                pairDetail(pair)
            } else {
                Text(model.t("menubarNoPairs")).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(english ? "Pause this folder on this Mac?" : "在这台 Mac 暂停此目录同步？", isPresented: $state.confirmingPause) {
            Button(english ? "Pause and save" : "暂停并保存") { pauseFolder() }
            Button(model.t("cancel"), role: .cancel) { }
        } message: {
            Text(state.pauseFolder + (english ? "\nUploads and downloads for this entire folder will pause. Existing files stay in place. Restore normal sync in folder settings." : "\n整个目录的上传和下载都会暂停，现有文件保持原位。之后可在目录设置中恢复正常同步。"))
        }
    }

    private func pairDetail(_ pair: SyncPair) -> some View {
        let record = model.lastRecord(for: pair)
        let groups = record.map(syncIssueGroups) ?? []
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.pairStatus(pair).text)
                    .font(.callout).foregroundStyle(model.pairStatus(pair).color)
                Spacer()
                Button(model.t("syncShort")) { model.syncNow(pairID: pair.id) }
                    .disabled(!model.canRun(pair))
            }
            if model.isPairSyncActive(pair) {
                SyncPairProgressView(progress: model.progressForPair(pair), language: model.config.language,
                                     fallback: model.pairProgress[pair.id])
            }
            if groups.contains(where: \.online) {
                Text(english ? "Pending downloads are handled automatically during sync. Cloud-only folders stay excluded." : "待下载文件会在同步时自动处理；仅云端目录继续跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !groups.isEmpty {
                TextField(english ? "Filter affected files" : "筛选文件路径", text: $state.query)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in groupRows(group, pair: pair) }
                }
            } else if let record {
                if record.incompleteOrFailed && !model.isSyncActive {
                    Text(syncIssueSummary(record.output, language: model.config.language))
                        .textSelection(.enabled)
                } else if record.stopped {
                    Label(english ? "Sync stopped. Completed files are kept; sync again to continue." : "同步已停止。已完成的文件已保留，再次同步可继续。", systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label(english ? "No file issues" : "没有需要处理的文件", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } else if !model.isPairSyncActive(pair) {
                Text(english ? "No previous sync results" : "尚无同步结果").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func groupRows(_ group: SyncIssueGroup, pair: SyncPair) -> some View {
        let filtered = group.events.filter { state.query.isEmpty || $0.path.localizedCaseInsensitiveContains(state.query) }
        let paused = pair.cloudOnlyPaths.contains { group.folder == $0 || group.folder.hasPrefix($0 + "/") }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !group.online {
                    Text(group.events.first?.detail.contains("尚未跟上服务器元数据") == true
                         ? (english ? "OneDrive's folder list is not ready. Wait for OneDrive to update, then retry. The affected path was preserved." : "OneDrive 的目录还未更新完成。请等待 OneDrive 更新后重试，相关文件已保留。")
                         : (group.events.first?.detail ?? ""))
                        .font(.callout).textSelection(.enabled)
                }
                HStack {
                    Button(english ? "Open folder" : "打开目录") { openFolder(group, pair: pair) }
                    if group.canPauseFolder {
                        Button(paused ? (english ? "Folder paused" : "此目录已暂停") : (english ? "Pause folder…" : "暂停此目录…")) {
                            state.pauseFolder = group.folder
                            state.confirmingPause = true
                        }.disabled(paused || !canChangePolicy)
                    }
                }.controlSize(.small)
                DisclosureGroup(english ? "Files (\(filtered.count))" : "文件（\(filtered.count) 项）") {
                    ForEach(Array(filtered.prefix(50))) { event in
                        Text(event.path).font(.caption).textSelection(.enabled)
                    }
                    if filtered.count > 50 {
                        Text(english ? "Showing the first 50. Search above to narrow the list." : "显示前 50 项，可用上方的搜索框筛选。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("\(group.folder.isEmpty ? (english ? "Root files" : "根目录文件") : group.folder) · \(group.events.count) \(english ? "files" : "项")",
                  systemImage: group.online ? "arrow.down.circle" : "exclamationmark.circle")
                .foregroundStyle(group.online ? Color.secondary : Color.orange)
        }
    }

    private func openFolder(_ group: SyncIssueGroup, pair: SyncPair) {
        guard group.folder.isEmpty || (try? normalizeCloudOnlyPath(group.folder)) == group.folder else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: pair.cloudPath).appendingPathComponent(group.folder))
    }

    private func pauseFolder() {
        guard canChangePolicy, let pair = selected,
              let folder = try? normalizeCloudOnlyPath(state.pauseFolder), folder == state.pauseFolder,
              let index = model.config.pairs.firstIndex(where: { $0.id == pair.id }) else { return }
        if !model.config.pairs[index].cloudOnlyPaths.contains(folder) {
            model.config.pairs[index].cloudOnlyPaths.append(folder)
            model.save()
        }
    }
}

struct StopSyncButton: View {
    @ObservedObject var model: SyncModel
    var body: some View {
        Button { model.stopSync() } label: {
            Label(model.t(model.stoppingSync ? "stoppingSync" : "stopSync"), systemImage: "stop.circle")
        }
        .disabled(!model.canStopSync || model.stoppingSync)
        .help(model.config.language == "en" ? "Keep completed files and stop remaining work." : "保留已完成的文件，停止后续同步。")
    }
}
