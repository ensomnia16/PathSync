import Foundation
import SwiftUI

/// Progress is stage-specific. Scanning and Graph pagination have no known denominator.
struct SyncPairProgress: Codable, Equatable, Identifiable {
    enum Stage: String, Codable { case waiting, scanning, cloudIndex, files, finalizing }
    enum State: String, Codable { case active, completed, incomplete, stopped }
    let id: UUID
    var stage: Stage = .waiting
    var state: State = .active
    var processed = 0
    var total: Int?
    var downloadsRead = 0
    var downloadsTotal: Int?
    var scannedFolders = 0
    var scannedFiles = 0
    var scanSide = "local"
    var currentFile: String?
    var waitSeconds: Int?

    var fraction: Double? {
        if state == .completed { return 1 }
        guard stage == .files, let total, total > 0 else { return nil }
        return min(1, max(0, Double(processed) / Double(total)))
    }

    @discardableResult
    mutating func consume(_ fields: [Substring]) -> Bool {
        guard fields.first == "PROGRESS", fields.count >= 3 else { return false }
        switch fields[1] {
        case "SCAN", "SCAN_DONE":
            guard fields.count == 5, let folders = Int(fields[3]), let files = Int(fields[4]), folders >= 0, files >= 0 else { return false }
            stage = .scanning; scanSide = String(fields[2]); scannedFolders = folders; scannedFiles = files
        case "GRAPH": stage = .cloudIndex
        case "PROCESS":
            guard fields.count == 4, let done = Int(fields[2]), let count = Int(fields[3]), done >= 0, count >= 0, done <= count else { return false }
            stage = .files; processed = done; total = count; currentFile = nil; waitSeconds = nil
        case "PREFETCH":
            guard fields.count == 4, let done = Int(fields[2]), let count = Int(fields[3]), done >= 0, count >= 0, done <= count else { return false }
            downloadsRead = done; downloadsTotal = count; waitSeconds = nil
        case "FILE": currentFile = fields.dropFirst(2).joined(separator: "\t"); waitSeconds = nil
        case "WAIT":
            guard fields.count >= 4, let seconds = Int(fields.last!), seconds >= 0 else { return false }
            currentFile = fields.dropFirst(2).dropLast().joined(separator: "\t"); waitSeconds = seconds
        case "FINALIZE": stage = .finalizing; currentFile = nil; waitSeconds = nil
        default: return false
        }
        return true
    }

    func label(language: String) -> String {
        let en = language == "en"
        switch state {
        case .completed: return en ? "Completed" : "已完成"
        case .incomplete: return en ? "Incomplete — view details" : "未完成，请查看详情"
        case .stopped: return en ? "Stopped" : "已停止"
        case .active: break
        }
        if let waitSeconds { return en ? "Waiting for OneDrive (\(waitSeconds)s)" : "等待 OneDrive 响应（\(waitSeconds) 秒）" }
        switch stage {
        case .waiting: return en ? "Preparing…" : "正在准备…"
        case .cloudIndex: return en ? "Checking cloud index…" : "正在查询云端增量索引…"
        case .scanning:
            let side = en ? (scanSide == "cloud" ? "OneDrive" : "local") : (scanSide == "cloud" ? "OneDrive" : "本地")
            return en ? "Scanning \(side): \(scannedFiles) files" : "扫描\(side)目录：已发现 \(scannedFiles) 个文件"
        case .files: return en ? "Files checked: \(processed) / \(total ?? 0)" : "核对文件：\(processed) / \(total ?? 0)"
        case .finalizing: return en ? "Checking packages and saving results…" : "正在核对包文件并保存结果…"
        }
    }

    func message(pairName: String, language: String) -> String {
        pairName + (language == "en" ? ": " : "：") + label(language: language)
            + (currentFile.map { " · " + $0 } ?? "")
    }
}

struct SyncProgressSnapshot: Codable, Equatable {
    let runID: String
    var pairs: [SyncPairProgress]
    var finishedCount: Int { pairs.filter { $0.state != .active }.count }

    static func read(runID: String, at path: String) -> Self? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = FileManager.default.contents(atPath: path), data.count <= 1_048_576,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.runID == runID, !value.pairs.isEmpty,
              Set(value.pairs.map(\.id)).count == value.pairs.count else { return nil }
        return value
    }
}

/// One writer per locked run, shared by parallel pairs and polled by any GUI instance.
final class SyncProgressStore {
    private let lock = NSLock()
    private var snapshot: SyncProgressSnapshot
    private let path: String
    private var lastWrite = Date.distantPast

    init(runID: String, pairIDs: [UUID], path: String) {
        self.path = path
        snapshot = SyncProgressSnapshot(runID: runID, pairs: pairIDs.map { SyncPairProgress(id: $0) })
        write(force: true)
    }

    func update(_ value: SyncPairProgress) {
        lock.lock(); defer { lock.unlock() }
        guard let index = snapshot.pairs.firstIndex(where: { $0.id == value.id }) else { return }
        snapshot.pairs[index] = value
        write(force: value.state != .active)
    }

    func complete(_ id: UUID, state: SyncPairProgress.State) {
        lock.lock(); defer { lock.unlock() }
        guard let index = snapshot.pairs.firstIndex(where: { $0.id == id }) else { return }
        snapshot.pairs[index].state = state
        write(force: true)
    }

    private func write(force: Bool) {
        guard force || Date().timeIntervalSince(lastWrite) >= 0.25 else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Telemetry failure must never interrupt or alter a sync operation.
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            lastWrite = Date()
        } catch { }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if SyncProgressSnapshot.read(runID: snapshot.runID, at: path) != nil {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

struct SyncPairProgressView: View {
    let progress: SyncPairProgress?
    let language: String
    var fallback: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(progress?.label(language: language) ?? fallback ?? (language == "en" ? "Syncing…" : "正在同步…"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let value = progress?.fraction {
                ProgressView(value: value).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let progress, progress.state == .active, let total = progress.downloadsTotal, total > 0 {
                Text(language == "en" ? "Download files handled: \(progress.downloadsRead) / \(total)" : "待读取文件：已处理 \(progress.downloadsRead) / \(total)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(language == "en" ? "File count, including failed attempts. This is not a network transfer percentage." : "按文件数量统计，包含读取失败的尝试；不是网络传输百分比。")
                ProgressView(value: Double(progress.downloadsRead), total: Double(total)).progressViewStyle(.linear)
            }
            if let file = progress?.currentFile {
                Text(file).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SyncRunProgressView: View {
    let snapshot: SyncProgressSnapshot?
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let snapshot {
                Text(language == "en" ? "Folders finished: \(snapshot.finishedCount) / \(snapshot.pairs.count)" : "已结束 \(snapshot.finishedCount) / \(snapshot.pairs.count) 组")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(snapshot.finishedCount), total: Double(snapshot.pairs.count)).progressViewStyle(.linear)
            } else {
                Text(language == "en" ? "Sync in progress…" : "同步进行中…").font(.caption).foregroundStyle(.secondary)
                ProgressView().progressViewStyle(.linear)
            }
        }
    }
}
