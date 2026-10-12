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

    var needsAttention: Bool {
        exitCode != nil && (counts["failed", default: 0] > 0 || exitCode != 0
            || counts["reviews", default: 0] > 0
            || counts["pending_delete", default: 0] > 0
            || (!isPreview && counts["kept_both", default: 0] > 0))
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
            guard columns.count >= 2,
                  ["FAILED", "CONFLICT", "KEPT_BOTH", "WOULD_KEEP_BOTH", "NEEDS_REVIEW",
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

func readSyncHistory(at path: String, maxBytes: UInt64 = 2_000_000) throws -> [SyncHistoryRecord] {
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

    init(path: String, maxBytes: Int = 2_000_000) {
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
