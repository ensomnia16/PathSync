import Foundation

struct SyncHistoryEvent: Identifiable {
    let id: Int
    let kind: String
    let path: String
    let detail: String
    let copyPath: String?
    let backupID: String?
    let side: String?
    let reason: String?
}

struct SyncHistoryRecord: Identifiable {
    let id: Int
    let startedAt: Date
    let pairName: String
    let direction: String
    let sourcePath: String
    let destinationPath: String
    let isPreview: Bool
    var finishedAt: Date?
    var exitCode: Int?
    var output = ""
    var counts: [String: Int] = [:]
    var events: [SyncHistoryEvent] = []

    var needsManualReview: Bool {
        counts["reviews", default: 0] > 0
            || (!isPreview && counts["reviews"] == nil && counts["kept_both", default: 0] > 0)
    }

    var incompleteOrFailed: Bool {
        finishedAt == nil || (exitCode != .some(0) && !stopped) || hasFailures
    }

    var stopped: Bool { finishedAt != nil && exitCode == 130 }

    var awaitingDownloadOnly: Bool {
        finishedAt != nil && exitCode == 2 && counts["online_only", default: 0] > 0
            && counts["failed", default: 0] == counts["online_only", default: 0]
            && !events.filter { $0.kind == "FAILED" }.isEmpty
            && events.filter { $0.kind == "FAILED" }.allSatisfy { $0.detail.contains("仅在线文件未下载") }
    }

    var needsAttention: Bool {
        (incompleteOrFailed && !awaitingDownloadOnly) || needsManualReview || counts["pending_delete", default: 0] > 0 || counts["conflicts", default: 0] > 0
    }

    var hasFailures: Bool {
        counts["failed", default: 0] > 0 || events.contains { $0.kind == "FAILED" }
    }

    var hasChanges: Bool {
        ["uploaded", "downloaded", "copied", "kept_both", "newest", "deleted",
         "pending_delete", "backups", "reviews", "conflicts", "failed"]
            .contains { counts[$0, default: 0] > 0 }
    }

    mutating func finishParsing() {
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Number of files transferred: "),
               let amount = Int(line.dropFirst("Number of files transferred: ".count)) {
                if direction == "本地 → 云端" { counts["uploaded"] = amount }
                if direction == "云端 → 本地" { counts["downloaded"] = amount }
                if direction == "双向合并" { counts["copied"] = amount }
            }
            let words = line.split(separator: " ")
            for word in words {
                let parts = word.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let value = Int(parts[1]) {
                    counts[String(parts[0])] = value
                }
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // Old readers emitted a multiline Python traceback. Keep its final
            // exception visible instead of only the uninformative first line.
            if columns.count == 1, let last = events.last,
               last.kind == "FAILED", last.detail == "Traceback (most recent call last):",
               line.range(of: #"^[A-Za-z_][A-Za-z_0-9.]*(Error|Exception):"#, options: .regularExpression) != nil {
                events[events.count - 1] = SyncHistoryEvent(id: last.id, kind: last.kind,
                    path: last.path, detail: String(line), copyPath: last.copyPath,
                    backupID: last.backupID, side: last.side, reason: last.reason)
            }
            guard columns.count >= 2,
                  ["FAILED", "SKIPPED", "CONFLICT", "KEPT_BOTH", "WOULD_KEEP_BOTH", "NEEDS_REVIEW",
                   "BACKUP", "DELETED", "PENDING_DELETE", "WOULD_DELETE", "NEWEST", "WOULD_KEEP_NEWEST",
                   "RESTORED", "RESOLVED", "REVIEW_NEWEST", "ACKNOWLEDGED"].contains(columns[0]) else { continue }
            let copy = columns.first(where: { $0.hasPrefix("copy=") }).map { String($0.dropFirst(5)) }
            let backupID = columns.first(where: { $0.hasPrefix("id=") }).map { String($0.dropFirst(3)) }
            let side = columns.first(where: { $0.hasPrefix("side=") }).map { String($0.dropFirst(5)) }
            let reason = columns.first(where: { $0.hasPrefix("reason=") }).map { String($0.dropFirst(7)) }
            let detail = columns.dropFirst(2)
                .filter { !$0.hasPrefix("copy=") && !$0.hasPrefix("backup=")
                    && !$0.hasPrefix("id=") && !$0.hasPrefix("side=") && !$0.hasPrefix("reason=") }
                .joined(separator: " · ")
            events.append(SyncHistoryEvent(id: events.count, kind: columns[0],
                                           path: columns[1], detail: detail, copyPath: copy,
                                           backupID: backupID, side: side, reason: reason))
        }
    }
}

private func logEntry(_ line: String, formatter: ISO8601DateFormatter) -> (Date, String)? {
    guard line.count > 21, line.dropFirst(20).first == " ",
          let date = formatter.date(from: String(line.prefix(20))) else { return nil }
    return (date, String(line.dropFirst(21)))
}

private func startRecord(_ body: String, date: Date, id: Int) -> SyncHistoryRecord? {
    let preview = body.hasPrefix("预览 [")
    guard preview || body.hasPrefix("开始 ["),
          let opening = body.firstIndex(of: "["),
          let closing = body[body.index(after: opening)...].firstIndex(of: "]") else { return nil }
    let pair = String(body[body.index(after: opening)..<closing])
    let remainder = String(body[body.index(after: closing)...]).trimmingCharacters(in: .whitespaces)
    guard let colon = remainder.firstIndex(of: "：") else { return nil }
    let direction = String(remainder[..<colon])
    let paths = String(remainder[remainder.index(after: colon)...])
        .components(separatedBy: " → ")
    guard paths.count == 2 else { return nil }
    return SyncHistoryRecord(id: id, startedAt: date, pairName: pair,
                             direction: direction, sourcePath: paths[0],
                             destinationPath: paths[1], isPreview: preview)
}

/// Folder pairs run in parallel, so their log entries interleave. A record is
/// matched to its end by pair name; the end entry's output lines follow it
/// contiguously because each log entry is a single write.
func parseSyncHistory(_ text: String) -> [SyncHistoryRecord] {
    let formatter = ISO8601DateFormatter()
    var records: [SyncHistoryRecord] = []
    var open: [String: SyncHistoryRecord] = [:]
    var trailing: SyncHistoryRecord?
    var started = 0

    func finish(_ record: SyncHistoryRecord) {
        var record = record
        record.finishParsing()
        records.append(record)
    }

    func flushTrailing() {
        if let record = trailing { finish(record) }
        trailing = nil
    }

    for line in text.components(separatedBy: .newlines) {
        guard let (date, body) = logEntry(line, formatter: formatter) else {
            trailing?.output += "\n" + line
            continue
        }
        flushTrailing()
        if body.hasPrefix("结束 ["),
           let name = open.keys.first(where: { body.hasPrefix("结束 [\($0)]，退出码 ") }),
           var record = open[name], let colon = body.firstIndex(of: "：") {
            let codeStart = body.range(of: "，退出码 ")!.upperBound
            record.exitCode = Int(body[codeStart..<colon])
            record.finishedAt = date
            record.output = String(body[body.index(after: colon)...])
            open[name] = nil
            trailing = record
            continue
        }
        if body.hasPrefix("失败 ["),
           let name = open.keys.first(where: { body.hasPrefix("失败 [\($0)]：") }),
           var record = open[name] {
            record.finishedAt = date
            record.exitCode = 1
            record.output = "FAILED\t\(name)\t" + String(body.dropFirst("失败 [\(name)]：".count))
            open[name] = nil
            finish(record)
            continue
        }
        // A large per-file error list can push its start line outside the
        // bounded log tail. Preserve the completion summary instead of losing
        // the failed run and displaying a healthy menu-bar icon after restart.
        if (body.hasPrefix("结束 [") || body.hasPrefix("失败 [")),
           let opening = body.firstIndex(of: "["),
           let closing = body[body.index(after: opening)...].firstIndex(of: "]"),
           let colon = body.firstIndex(of: "：") {
            let name = String(body[body.index(after: opening)..<closing])
            if !records.contains(where: { $0.pairName == name
                && (body.hasPrefix("失败 [") || $0.finishedAt == date) }) {
                var record = SyncHistoryRecord(id: started, startedAt: date, pairName: name,
                    direction: "双向合并", sourcePath: "", destinationPath: "", isPreview: false)
                started += 1
                record.finishedAt = date
                if let code = body.range(of: "，退出码 ") {
                    record.exitCode = Int(body[code.upperBound..<colon])
                } else {
                    record.exitCode = 1
                }
                record.output = String(body[body.index(after: colon)...])
                trailing = record
            }
            continue
        }
        if let record = startRecord(body, date: date, id: started) {
            started += 1
            if let interrupted = open[record.pairName] { finish(interrupted) }
            open[record.pairName] = record
        }
    }
    flushTrailing()
    open.values.forEach(finish)
    return records.sorted { $0.id > $1.id }
}

func readSyncHistory(at path: String, maxBytes: UInt64 = 16_000_000) throws -> [SyncHistoryRecord] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let offset = size > maxBytes ? size - maxBytes : 0
    try handle.seek(toOffset: offset)
    var text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    if offset > 0, let newline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: newline)...])
    }
    return Array(parseSyncHistory(text).prefix(200))
}

/// Keeps the parsed tail of sync.log between refreshes and reads only the bytes
/// appended since the last call. Use from one queue at a time.
final class SyncHistoryReader {
    let path: String
    let maxBytes: Int
    private var buffer = Data()
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var records: [SyncHistoryRecord] = []

    init(path: String, maxBytes: Int = 16_000_000) {
        self.path = path
        self.maxBytes = maxBytes
    }

    func read() throws -> [SyncHistoryRecord] {
        var info = stat()
        guard stat(path, &info) == 0 else {
            buffer = Data()
            offset = 0
            fileID = nil
            records = []
            return []
        }
        let size = UInt64(info.st_size)
        let inode = UInt64(info.st_ino)
        if fileID == inode && size == offset { return records }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var cutMidLine = false
        if fileID != inode || size < offset {
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            buffer = Data()
            offset = start
            cutMidLine = start > 0
        }
        try handle.seek(toOffset: offset)
        let appended = handle.readDataToEndOfFile()
        offset += UInt64(appended.count)
        buffer.append(appended)
        if buffer.count > maxBytes {
            buffer = Data(buffer.suffix(maxBytes))
            cutMidLine = true
        }
        if cutMidLine, let newline = buffer.firstIndex(of: 10) {
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        fileID = inode
        records = Array(parseSyncHistory(String(decoding: buffer, as: UTF8.self)).prefix(200))
        return records
    }
}

/// Human-facing diagnosis from file events, never from trailing telemetry.
func syncIssueSummary(_ output: String, language: String = "zh-Hans") -> String {
    let english = language == "en"
    let failures = output.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.first == "FAILED", fields.count >= 2 else { return nil }
        return (String(fields[1]), fields.count > 2 ? String(fields[2]) : String(fields[1]))
    }
    let online = failures.filter { $0.1.contains("仅在线文件未下载") }
    let other = failures.filter { !$0.1.contains("仅在线文件未下载") }
    var messages: [String] = []
    if !online.isEmpty {
        var folders: [String: Int] = [:]
        for (path, _) in online {
            let components = path.split(separator: "/")
            let folder = components.count > 1 ? String(components[0]) : (english ? "Root files" : "根目录文件")
            folders[folder, default: 0] += 1
        }
        let sorted = folders.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let locations = sorted.prefix(4).map { "\($0.key)（\($0.value)）" }.joined(separator: "、")
        let remaining = sorted.count > 4 ? (english ? "; more folders in History" : "；其余目录见同步记录") : ""
        messages.append(english
            ? "\(online.count) online-only files need a decision: \(locations)\(remaining). No automatic download. To keep them in the cloud, add the specific subfolder to Cloud only and save; to keep a local copy, download the chosen files in OneDrive, then sync again."
            : "\(online.count) 个仅在线文件待处理：\(locations)\(remaining)。未自动下载。只需云端保留：将对应子目录加入‘仅云端’并保存（该目录的上传也会暂停）；需要本地副本：在 OneDrive 下载所选文件后重试。")
    }
    if let first = other.first {
        messages.append(english ? "\(other.count) file errors. \(first.0): \(first.1)" : "\(other.count) 项文件错误。\(first.0)：\(first.1)")
        if other.contains(where: { $0.1.contains("尚未跟上服务器元数据") }) {
            messages.append(english ? "Wait for OneDrive to finish updating its folder list, then retry. The affected paths were preserved; nothing was overwritten or deleted there." : "请等待 OneDrive 完成目录更新后重试；相关路径已保留，未覆盖或删除。若持续出现，请检查 OneDrive 目录状态。")
        }
    }
    if messages.isEmpty {
        // Keep actual diagnostic output, excluding protocol, counters and statistics.
        let diagnostic = output.split(whereSeparator: \.isNewline).last { line in
            !line.contains("GRAPH_INDEX") && !line.hasPrefix("PROGRESS\t")
                && !line.hasPrefix("SYNC_PLAN\t") && !line.hasPrefix("uploaded=")
                && !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        messages.append(diagnostic.map(String.init) ?? (english ? "Run did not complete; see History for details." : "本次运行未完成，请查看同步记录。"))
    }
    return messages.joined(separator: "\n")
}

struct SyncIssueGroup: Identifiable {
    let folder: String
    let online: Bool
    let events: [SyncHistoryEvent]
    var id: String { (online ? "online:" : "error:") + folder }
    var canPauseFolder: Bool {
        online && !folder.isEmpty && !folder.hasPrefix("/")
            && !folder.split(separator: "/").contains("..")
            && events.allSatisfy { $0.path.hasPrefix(folder + "/") }
    }
}

func syncIssueGroups(_ record: SyncHistoryRecord) -> [SyncIssueGroup] {
    let failures = record.events.filter { $0.kind == "FAILED" }
    let grouped = Dictionary(grouping: failures) { event -> String in
        let online = event.detail.contains("仅在线文件未下载")
        let parts = event.path.split(separator: "/")
        return (online ? "online:" : "error:") + (parts.count > 1 ? String(parts[0]) : "")
    }
    return grouped.map { key, events in
        SyncIssueGroup(folder: String(key.dropFirst(key.hasPrefix("online:") ? 7 : 6)),
                       online: key.hasPrefix("online:"), events: events)
    }.sorted { $0.events.count == $1.events.count ? $0.id < $1.id : $0.events.count > $1.events.count }
}
