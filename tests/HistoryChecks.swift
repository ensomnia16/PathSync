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
        assert(records[3].needsManualReview, "Legacy records without a review count remain reviewable")
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

        let automaticCopy = """
        2026-11-07T13:48:00Z 开始 [科研] 双向合并：/local → /cloud
        2026-11-07T13:50:00Z 结束 [科研]，退出码 0：KEPT_BOTH\tmain.log\tcopy=main (cloud conflict abc).log
        uploaded=0 downloaded=597 kept_both=1 backups=1 reviews=0 failed=0
        """
        let automatic = parseSyncHistory(automaticCopy)[0]
        assert(!automatic.needsAttention && !automatic.needsManualReview && automatic.hasChanges)
        let waiting = parseSyncHistory(automaticCopy.replacingOccurrences(of: "reviews=0", with: "reviews=1"))[0]
        assert(waiting.needsAttention && waiting.needsManualReview)

        let traceback = """
        2026-11-07T09:47:00Z 开始 [科研] 双向合并：/local → /cloud
        2026-11-07T09:47:01Z 结束 [科研]，退出码 2：FAILED\tfile.pdf\tTraceback (most recent call last):
          File "<string>", line 3, in <module>
        OSError: [Errno 11] Resource deadlock avoided
        FAILED\tmissing.txt\tFile does not exist
        uploaded=0 downloaded=0 failed=2
        """
        let traced = parseSyncHistory(traceback)
        assert(traced[0].events[0].detail == "OSError: [Errno 11] Resource deadlock avoided")
        assert(traced[0].events[1].detail == "File does not exist")
        assert(traced[0].counts["failed"] == 2)

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
        let onlineFailure = "FAILED\tCityU Meeting/archive/a.pdf\t仅在线文件未下载，保留\nFAILED\tKTH/a.zip\t云端内容待核验：仅在线文件未下载\nuploaded=0 downloaded=0 failed=2\nGRAPH_INDEX\t{\"pages\":1}"
        let diagnosis = syncIssueSummary(onlineFailure)
        assert(diagnosis.contains("2 个仅在线文件待处理"))
        assert(diagnosis.contains("CityU Meeting（1）") && diagnosis.contains("KTH（1）"))
        assert(diagnosis.contains("上传也会暂停"))
        assert(!diagnosis.contains("GRAPH_INDEX"))
        let mismatch = syncIssueSummary("FAILED\tcache/a.pkgf\tOneDrive 本地目录尚未跟上服务器元数据；保留文件与基线\nGRAPH_INDEX\t{}")
        assert(mismatch.contains("cache/a.pkgf"))
        assert(mismatch.contains("等待 OneDrive"))
        assert(syncIssueSummary("PermissionError: denied\nGRAPH_INDEX\t{}").contains("PermissionError: denied"))
        assert(!syncIssueSummary("GRAPH_INDEX\t{}").contains("GRAPH_INDEX"))
        var actionable = SyncHistoryRecord(id: 99, startedAt: Date(), pairName: "Test", direction: "双向合并", sourcePath: "/l", destinationPath: "/c", isPreview: false)
        actionable.output = onlineFailure + "\nFAILED\troot.pdf\t仅在线文件未下载\nFAILED\t../escape.txt\t仅在线文件未下载\nFAILED\tcache/a.pkgf\tOneDrive 本地目录尚未跟上服务器元数据"
        actionable.finishParsing()
        let groups = syncIssueGroups(actionable)
        assert(groups.filter { $0.online }.count == 4)
        assert(groups.first { $0.folder == "CityU Meeting" }!.canPauseFolder)
        assert(!groups.first { $0.folder.isEmpty }!.canPauseFolder)
        assert(!groups.first { $0.folder == ".." }!.canPauseFolder)
        assert(groups.first { $0.folder == "cache" }!.online == false)
        let largeLog = temporary.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: largeLog) }
        let manyFailures = (0..<12858).map { "FAILED\tCityU Meeting/archive/item-\($0).pdf\t仅在线文件未下载；保留文件和基线，当前设置不会自动下载云端文件。请在界面选择保留云端还是下载到本地。" }.joined(separator: "\n")
        let largeRun = "2026-11-08T03:12:40Z 开始 [大目录] 双向合并：/local → /cloud\n2026-11-08T03:12:44Z 结束 [大目录]，退出码 2：" + manyFailures + "\nuploaded=0 downloaded=0 failed=12858 online_only=12858\nGRAPH_INDEX\t{}\n2026-11-08T03:12:44Z 失败 [大目录]：未完全成功：GRAPH_INDEX\t{}\n"
        assert(largeRun.utf8.count > 2_000_000)
        try largeRun.write(to: largeLog, atomically: true, encoding: .utf8)
        assert(syncIssueGroups(try readSyncHistory(at: largeLog.path)[0])[0].events.count == 12858)
        assert(syncIssueGroups(try SyncHistoryReader(path: largeLog.path).read()[0])[0].events.count == 12858)
        print("History parser checks passed")
    }
}
