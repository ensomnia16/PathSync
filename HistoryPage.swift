import AppKit
import SwiftUI

private final class HistoryFilters: ObservableObject {
    @Published var pair = "all"
    @Published var result = "all"
}

struct HistoryPage: View {
    let records: [SyncHistoryRecord]
    let pairs: [SyncPair]
    let language: String
    let error: String?
    let refresh: () -> Void
    let restore: (SyncPair, String) -> Void

    @StateObject private var filters = HistoryFilters()

    private func t(_ key: String) -> String { uiText(key, language: language) }

    private var filteredRecords: [SyncHistoryRecord] {
        records.filter { record in
            let matchesPair = filters.pair == "all" || pairs.contains { pair in
                pair.id.uuidString == filters.pair && (
                    (record.sourcePath == pair.localPath && record.destinationPath == pair.cloudPath)
                    || (record.sourcePath == pair.cloudPath && record.destinationPath == pair.localPath))
            }
            let matchesResult = filters.result == "all"
                || (filters.result == "changes" && record.hasChanges)
                || (filters.result == "attention" && record.needsAttention)
            return matchesPair && matchesResult
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: usesEnglish(language) ? "en" : "zh-Hans")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func pairForRecord(_ record: SyncHistoryRecord) -> SyncPair? {
        pairs.first { pair in
            (record.sourcePath == pair.localPath && record.destinationPath == pair.cloudPath)
                || (record.sourcePath == pair.cloudPath && record.destinationPath == pair.localPath)
        }
    }

    private func directionText(_ direction: String) -> String {
        switch direction {
        case "双向合并": return t("merge")
        case "本地 → 云端": return t("upload")
        case "云端 → 本地": return t("download")
        default: return direction
        }
    }

    private func resultText(_ record: SyncHistoryRecord) -> String {
        if record.finishedAt == nil { return t("historyInterrupted") }
        if record.hasFailures { return t("historyFailed") }
        if record.counts["pending_delete", default: 0] > 0 { return t("historyPendingDelete") }
        if record.counts["reviews", default: 0] > 0
            || (!record.isPreview && record.counts["kept_both", default: 0] > 0) {
            return t("historyReview")
        }
        if record.needsAttention { return t("historyAttention") }
        return record.isPreview ? t("historyPreview") : t("historyCompleted")
    }

    private func resultIcon(_ record: SyncHistoryRecord) -> String {
        if record.finishedAt == nil { return "minus.circle" }
        if record.hasFailures { return "xmark.octagon.fill" }
        if record.needsAttention { return "exclamationmark.triangle.fill" }
        return record.isPreview ? "eye.circle.fill" : "checkmark.circle.fill"
    }

    private func resultColor(_ record: SyncHistoryRecord) -> Color {
        if record.finishedAt == nil { return .secondary }
        if record.hasFailures { return .red }
        if record.needsAttention { return .orange }
        return record.isPreview ? .blue : .green
    }

    private func summary(_ record: SyncHistoryRecord) -> String {
        let copied = record.counts["copied", default: 0]
        let uploaded = record.counts["uploaded"] ?? (record.direction == "本地 → 云端" ? copied : 0)
        let downloaded = record.counts["downloaded"] ?? (record.direction == "云端 → 本地" ? copied : 0)
        let values: [(String, Int)] = [
            ("historyUploaded", uploaded),
            ("historyDownloaded", downloaded),
            ("historyCopied", record.direction == "双向合并" ? copied : 0),
            (record.isPreview ? "historyWouldKeepBoth" : "historyKeptBoth",
             record.counts["kept_both", default: 0]),
            ("historyReviews", record.counts["reviews", default: 0]),
            ("historyNewest", record.counts["newest", default: 0]),
            ("historyDeleted", record.counts["deleted", default: 0]),
            ("historyPendingDelete", record.counts["pending_delete", default: 0]),
            ("historyBackups", record.counts["backups", default: 0]),
            ("historyConflicts", record.counts["conflicts", default: 0]),
            ("historyFailures", record.counts["failed", default: 0])
        ]
        let parts = values.filter { $0.1 > 0 }.map { "\(t($0.0)) \($0.1)" }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if record.events.contains(where: { $0.kind == "REVIEW_NEWEST" }) { return t("newestResolved") }
        if record.events.contains(where: { $0.kind == "RESTORED" }) { return t("backupRestored") }
        if record.events.contains(where: { $0.kind == "ACKNOWLEDGED" }) { return t("reviewAcknowledged") }
        if record.events.contains(where: { $0.kind == "RESOLVED" }) { return t("resolved") }
        let hasCounts = ["uploaded", "downloaded", "copied", "unchanged", "skipped",
                         "kept_both", "newest", "deleted", "pending_delete", "backups", "reviews",
                         "conflicts", "failed"].contains { record.counts[$0] != nil }
        return hasCounts ? t("historyNoChanges") : t("historyNoSummary")
    }

    private func eventText(_ event: SyncHistoryEvent) -> String {
        switch event.kind {
        case "KEPT_BOTH": return t("historyKeptBoth")
        case "WOULD_KEEP_BOTH": return t("historyWouldKeepBoth")
        case "NEEDS_REVIEW": return t("historyReview")
        case "BACKUP": return event.reason == "delete" ? t("historyDeleteBackup") : t("historyBackup")
        case "DELETED", "WOULD_DELETE": return t("historyDeleted")
        case "PENDING_DELETE": return t("historyPendingDelete")
        case "NEWEST", "WOULD_KEEP_NEWEST": return t("historyNewest")
        case "RESTORED": return t("backupRestored")
        case "REVIEW_NEWEST": return t("historyNewest")
        case "ACKNOWLEDGED": return t("reviewAcknowledged")
        case "RESOLVED": return t("resolved")
        case "CONFLICT": return t("historyConflicts")
        default: return t("historyFailures")
        }
    }

    private func recordRow(_ record: SyncHistoryRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(t("historyDirection"), value: directionText(record.direction))
                LabeledContent(t("historyResult"), value: summary(record))
                if !record.events.isEmpty {
                    Divider()
                    ForEach(record.events) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(eventText(event)) · \(event.path)")
                                .font(.callout)
                                .textSelection(.enabled)
                            if let copy = event.copyPath {
                                Text("\(t("historyCopy")) \(copy)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if !event.detail.isEmpty {
                                Text(event.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if event.kind == "BACKUP", let id = event.backupID,
                               let pair = pairForRecord(record) {
                                HStack(spacing: 10) {
                                    Text(t(event.side == "cloud" ? "backupSideCloud" : "backupSideLocal"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if backupAvailable(pair, id: id) {
                                        Button(t("restoreBackup")) { restore(pair, id) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    } else {
                                        Text(t("backupExpired"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text(t("historyNoFileDetails"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 28)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: resultIcon(record))
                    .foregroundStyle(resultColor(record))
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.pairName).font(.headline)
                        if record.isPreview && record.needsAttention {
                            Text(t("historyPreview"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(summary(record))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(resultText(record)).foregroundStyle(resultColor(record))
                    Text(dateText(record.finishedAt ?? record.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .padding(.vertical, 5)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("historyTitle")).font(.title2.bold())
                    Text(String(format: t("historyCount"), records.count, filteredRecords.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(t("historyHistoricalHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { refresh() } label: {
                    Label(t("historyRefresh"), systemImage: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            HStack(spacing: 12) {
                Picker(t("historyFolderFilter"), selection: $filters.pair) {
                    Text(t("historyAllFolders")).tag("all")
                    ForEach(pairs) { pair in
                        Text(pair.name).tag(pair.id.uuidString)
                    }
                }
                Picker(t("historyResultFilter"), selection: $filters.result) {
                    Text(t("historyAllResults")).tag("all")
                    Text(t("historyWithChanges")).tag("changes")
                    Text(t("historyAttention")).tag("attention")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if let error {
                Text(error).foregroundStyle(.red).padding(24)
                Spacer()
            } else if filteredRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(records.isEmpty ? t("historyEmpty") : t("historyFilterEmpty"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRecords) { record in
                    recordRow(record)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
                } label: {
                    Label(t("log"), systemImage: "doc.text")
                }
                .buttonStyle(.link)
                Spacer()
                Text(t("historyLogHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .frame(height: 44)
        }
    }
}
