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

func parseSyncHistory(_ text: String) -> [SyncHistoryRecord] {
    let formatter = ISO8601DateFormatter()
    var records: [SyncHistoryRecord] = []
    var current: SyncHistoryRecord?

    func flush() {
        if var record = current {
            record.finishParsing()
            records.append(record)
        }
        current = nil
    }

    for line in text.components(separatedBy: .newlines) {
        if let (date, body) = logEntry(line, formatter: formatter) {
            if body.hasPrefix("结束 ["), var record = current,
               body.hasPrefix("结束 [\(record.pairName)]，退出码 "),
               let colon = body.firstIndex(of: "：") {
                let codeStart = body.range(of: "，退出码 ")!.upperBound
                record.exitCode = Int(body[codeStart..<colon])
                record.finishedAt = date
                record.output = String(body[body.index(after: colon)...])
                current = record
                continue
            }
            if body.hasPrefix("失败 ["), var record = current,
               record.finishedAt == nil,
               body.hasPrefix("失败 [\(record.pairName)]：") {
                record.finishedAt = date
                record.exitCode = 1
                record.output = "FAILED\t\(record.pairName)\t"
                    + String(body.dropFirst("失败 [\(record.pairName)]：".count))
                current = record
                flush()
                continue
            }
            flush()
            current = startRecord(body, date: date, id: records.count)
        } else if current?.finishedAt != nil {
            current?.output += "\n" + line
        }
    }
    flush()
    return records.reversed()
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
