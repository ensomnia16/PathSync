import Foundation

@main
struct HistoryChecks {
    static func main() throws {
        let sample = """
        2026-09-23T10:04:44Z 预览 [科研] 双向合并：/local → /cloud
        2026-09-23T10:04:45Z 结束 [科研]，退出码 2：CONFLICT\tmain.tex\t两侧内容不同
        uploaded=1 downloaded=0 unchanged=7 kept_both=0 skipped=0 conflicts=1 failed=0
        2026-09-23T10:06:54Z 开始 [科研] 双向合并：/local → /cloud
        2026-09-23T10:06:57Z 结束 [科研]，退出码 0：KEPT_BOTH\tmain.tex\tcopy=main (cloud conflict abc).tex\tbackup=/backup
        BACKUP\tmain.tex\tside=cloud\tid=0123456789abcdef0123456789abcdef\treason=conflict-overwrite
        uploaded=1 downloaded=0 unchanged=7 kept_both=1 backups=1 skipped=0 conflicts=0 failed=0
        2026-09-23T10:08:00Z 开始 [科研] 双向合并：/local → /cloud
        2026-09-23T10:08:01Z 结束 [科研]，退出码 0：NEEDS_REVIEW\tmain.tex\tcopy=main (cloud conflict abc).tex
        uploaded=0 downloaded=0 unchanged=8 kept_both=0 skipped=0 conflicts=0 reviews=1 failed=0
        2026-09-23T10:11:27Z 开始 [实验室事务] 云端 → 本地：/cloud2 → /local2
        2026-09-23T10:11:29Z 结束 [实验室事务]，退出码 0：uploaded=0 downloaded=2 unchanged=4 kept_both=0 skipped=0 conflicts=0 failed=0
        2026-09-23T10:12:00Z 开始 [科研] 双向合并：/local → /cloud
        """
        let records = parseSyncHistory(sample)
        assert(records.count == 5)
        assert(records[0].finishedAt == nil)
        assert(records[1].pairName == "实验室事务")
        assert(records[1].counts["downloaded"] == 2)
        assert(records[2].counts["reviews"] == 1)
        assert(records[2].needsAttention)
        assert(records[2].events.first?.kind == "NEEDS_REVIEW")
        assert(records[3].counts["kept_both"] == 1)
        assert(records[3].events.count == 2)
        assert(records[3].events[0].copyPath == "main (cloud conflict abc).tex")
        assert(records[3].events[1].backupID == "0123456789abcdef0123456789abcdef")
        assert(records[3].events[1].side == "cloud")
        assert(records[3].events[1].reason == "conflict-overwrite")
        assert(records[3].needsAttention)
        assert(records[4].isPreview)
        assert(records[4].needsAttention)
        assert(records[4].events[0].path == "main.tex")

        let skipped = parseSyncHistory("""
        2026-10-27T16:20:00Z 开始 [研三] 双向合并：/local → /cloud
        2026-10-27T16:20:31Z 结束 [研三]，退出码 0：SKIPPED\talias.md\t路径是符号链接，保留两端文件
        uploaded=0 downloaded=0 unchanged=3 skipped=1 conflicts=0 failed=0
        """)
        assert(skipped.count == 1 && !skipped[0].hasFailures && !skipped[0].needsAttention)
        assert(skipped[0].events.first?.kind == "SKIPPED")
        assert(skipped[0].events.first?.path == "alias.md")
        assert(skipped[0].counts["skipped"] == 1)

        let launchFailure = """
        2026-09-23T11:00:00Z 开始 [科研] 双向合并：/local → /cloud
        2026-09-23T11:00:01Z 失败 [科研]：无法启动同步程序
        """
        let failed = parseSyncHistory(launchFailure)
        assert(failed.count == 1 && failed[0].needsAttention)
        assert(failed[0].events.first?.detail == "无法启动同步程序")

        let legacy = """
        2026-09-23T03:31:28Z 开始 [旧路径] 本地 → 云端：/old-local → /old-cloud
        2026-09-23T03:31:29Z 结束 [旧路径]，退出码 0：Number of files: 3
        Number of files transferred: 2
        Total file size: 22 B
        """
        assert(parseSyncHistory(legacy).first?.counts["uploaded"] == 2)

        // Parallel folder pairs interleave their start and end entries.
        let interleaved = """
        2026-10-09T10:00:00Z 开始 [A] 双向合并：/a-local → /a-cloud
        2026-10-09T10:00:00Z 开始 [B] 本地 → 云端：/b-local → /b-cloud
        2026-10-09T10:00:01Z 开始 [C] 双向合并：/c-local → /c-cloud
        2026-10-09T10:00:02Z 结束 [B]，退出码 0：uploaded=3 downloaded=0 failed=0
        2026-10-09T10:00:03Z 结束 [A]，退出码 2：FAILED\tx.tex\tunreadable
        uploaded=0 downloaded=1 failed=1
        2026-10-09T10:00:04Z 失败 [A]：「A」未完全成功
        2026-10-09T10:00:05Z 失败 [C]：无法启动同步程序
        """
        let parallel = parseSyncHistory(interleaved)
        assert(parallel.count == 3)
        assert(parallel.map(\.pairName) == ["C", "B", "A"])
        assert(parallel[1].counts["uploaded"] == 3 && parallel[1].exitCode == 0)
        assert(parallel[2].counts["downloaded"] == 1 && parallel[2].events.first?.kind == "FAILED")
        assert(parallel[2].exitCode == 2)
        assert(parallel[0].exitCode == 1 && parallel[0].events.first?.detail == "无法启动同步程序")

        let growing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: growing) }
        try "".write(to: growing, atomically: true, encoding: .utf8)
        let reader = SyncHistoryReader(path: growing.path, maxBytes: 400)
        let empty = try reader.read()
        assert(empty.isEmpty)
        let appendable = try FileHandle(forWritingTo: growing)
        func append(_ text: String) throws {
            try appendable.seekToEnd()
            try appendable.write(contentsOf: Data(text.utf8))
        }
        try append("2026-10-09T11:00:00Z 开始 [科研] 双向合并：/local → /cloud\n")
        let open = try reader.read()
        assert(open.count == 1 && open[0].finishedAt == nil)
        try append("2026-10-09T11:00:05Z 结束 [科研]，退出码 0：uploaded=2 failed=0\n")
        let done = try reader.read()
        assert(done.count == 1 && done[0].counts["uploaded"] == 2)
        for minute in 10..<20 {
            try append("2026-10-09T11:\(minute):00Z 开始 [科研] 双向合并：/local → /cloud\n")
            try append("2026-10-09T11:\(minute):30Z 结束 [科研]，退出码 0：downloaded=\(minute) failed=0\n")
        }
        try appendable.close()
        let trimmed = try reader.read()
        assert(trimmed.first?.counts["downloaded"] == 19)
        assert(trimmed.count < 12, "the reader keeps only the newest maxBytes of the log")
        assert(trimmed.allSatisfy { $0.finishedAt != nil })
        try "2026-10-09T12:00:00Z 开始 [新] 双向合并：/n → /m\n".write(to: growing, atomically: true, encoding: .utf8)
        let replaced = try reader.read()
        assert(replaced.map(\.pairName) == ["新"], "a replaced log is read again from the start")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        try sample.write(to: temporary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fromDisk = try readSyncHistory(at: temporary.path)
        assert(fromDisk.count == 5)
        print("History parser checks passed")
    }
}
