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
        uploaded=1 downloaded=0 unchanged=7 kept_both=1 skipped=0 conflicts=0 failed=0
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
        assert(records[3].events.count == 1)
        assert(records[3].events[0].copyPath == "main (cloud conflict abc).tex")
        assert(records[3].needsAttention)
        assert(records[4].isPreview)
        assert(records[4].needsAttention)
        assert(records[4].events[0].path == "main.tex")

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

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".log")
        try sample.write(to: temporary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fromDisk = try readSyncHistory(at: temporary.path)
        assert(fromDisk.count == 5)
        print("History parser checks passed")
    }
}
