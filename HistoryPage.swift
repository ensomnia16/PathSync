import AppKit
import SwiftUI

private final class HistoryFilters: ObservableObject {
    @Published var pair = "all"
    @Published var result = "all"
    @Published var latexDiff: LatexDiffResult?
    @Published var diffLoading = false
}

private final class LatexSummaryState: ObservableObject {
    @Published var loading = false
    @Published var summary: String?
    @Published var error: String?
}

private struct LatexDiffSheet: View {
    let result: LatexDiffResult
    let language: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ai = LatexSummaryState()
    private func t(_ key: String) -> String { uiText(key, language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("historyDiffTitle")).font(.title2.bold())
                Spacer()
                Button(t("historyClose")) { dismiss() }
            }
            if let error = result.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text(result.leftTitle + " ↔ " + result.rightTitle).font(.subheadline).foregroundStyle(.secondary)
                Text(result.summary).font(.callout)
                Text(t("historyDiffCurrentHint")).font(.caption).foregroundStyle(.secondary)
                if result.unifiedDiff.components(separatedBy: "\n").count > 4000 {
                    Text(t("historyDiffTruncated")).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(t("historyCodexSummary")) {
                        ai.loading = true
                        ai.error = nil
                        let language = language
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome = Result { try summarizeLatexDiffWithCodex(result, language: language) }
                            DispatchQueue.main.async {
                                ai.loading = false
                                switch outcome {
                                case .success(let value): ai.summary = value
                                case .failure(let error): ai.error = error.localizedDescription
                                }
                            }
                        }
                    }
                    .disabled(ai.loading || codexCLIPath() == nil)
                    if ai.loading { ProgressView().controlSize(.small) }
                    Text(t("historyCodexHint")).font(.caption).foregroundStyle(.secondary)
                }
                if let error = ai.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if let summary = ai.summary {
                    ScrollView { Text(summary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 120)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(result.unifiedDiff.components(separatedBy: "\n").prefix(4000).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("+") ? Color.green :
                                                 line.hasPrefix("-") ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color(nsColor: .separatorColor))
            }
        }
        .padding(20)
        .frame(width: 850, height: 650)
    }
}

struct HistoryPage: View {
    let records: [SyncHistoryRecord]
    let pairs: [SyncPair]
    let language: String
    let error: String?
    let refresh: () -> Void
    let restore: (SyncPair, String) -> Void
    let canRestore: Bool

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

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openBackup(_ url: URL, originalName: String) {
        // Backup payloads are stored as extensionless `content`. A temporary
        // link preserves the original extension for the user's usual editor.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pathsync-backup-view-" + UUID().uuidString)
        let link = folder.appendingPathComponent(URL(fileURLWithPath: originalName).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            NSWorkspace.shared.open(link)
        } catch {
            NSWorkspace.shared.open(url)
        }
    }

    private func historyFile(_ pair: SyncPair, _ name: String, cloud: Bool) -> URL? {
        safeHistoryFile(root: cloud ? pair.cloudPath : pair.localPath, relative: name)
    }

    private func existingHistoryFile(_ pair: SyncPair, _ name: String, cloud: Bool) -> URL? {
        guard let url = historyFile(pair, name, cloud: cloud),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func eventBackup(_ pair: SyncPair, _ event: SyncHistoryEvent) -> URL? {
        guard event.kind == "BACKUP", let id = event.backupID else { return nil }
        return backupContentURL(pair, id: id, name: event.path)
    }

    private func showLatexDiff(pair: SyncPair, event: SyncHistoryEvent) {
        guard !filters.diffLoading else { return }
        let backup = eventBackup(pair, event)
        let left = backup ?? existingHistoryFile(pair, event.path, cloud: false)
        let right = backup == nil
            ? event.copyPath.flatMap({ existingHistoryFile(pair, $0, cloud: false) })
                ?? existingHistoryFile(pair, event.path, cloud: true)
            : existingHistoryFile(pair, event.path, cloud: event.side == "cloud")
        guard let left, let right else { return }
        filters.diffLoading = true
        let language = language
        let leftTitle = backup == nil ? (usesEnglish(language) ? "Local current" : "本地当前文件")
            : uiText("historyBackupVersion", language: language)
        let rightTitle = backup != nil
            ? uiText(event.side == "cloud" ? "historyCurrentCloud" : "historyCurrentLocal", language: language)
            : event.copyPath ?? (usesEnglish(language) ? "Cloud current" : "云端当前文件")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = makeLatexDiff(left: left, right: right,
                leftTitle: leftTitle,
                rightTitle: rightTitle, language: language)
            DispatchQueue.main.async {
                filters.diffLoading = false
                filters.latexDiff = result
            }
        }
    }

    @ViewBuilder
    private func fileActions(_ pair: SyncPair, event: SyncHistoryEvent) -> some View {
        let local = existingHistoryFile(pair, event.path, cloud: false)
        let cloud = existingHistoryFile(pair, event.path, cloud: true)
        let copy = event.copyPath.flatMap { existingHistoryFile(pair, $0, cloud: false)
            ?? existingHistoryFile(pair, $0, cloud: true) }
        let backup = eventBackup(pair, event)
        if local != nil || cloud != nil || copy != nil || backup != nil {
            HStack(spacing: 8) {
                Menu(t("historyFileActions")) {
                    if let local {
                        Button(t("historyOpenLocal")) { NSWorkspace.shared.open(local) }
                        Button(t("historyRevealLocal")) { reveal(local) }
                    }
                    if let cloud {
                        Button(t("historyOpenCloud")) { NSWorkspace.shared.open(cloud) }
                        Button(t("historyRevealCloud")) { reveal(cloud) }
                    }
                    if let copy {
                        Button(t("historyOpenCopy")) { NSWorkspace.shared.open(copy) }
                        Button(t("historyRevealCopy")) { reveal(copy) }
                    }
                    if let backup {
                        Button(t("historyOpenBackup")) { openBackup(backup, originalName: event.path) }
                        Button(t("historyRevealBackup")) { reveal(backup) }
                    }
                }
                if ["tex", "bib", "sty", "cls"].contains(URL(fileURLWithPath: event.path).pathExtension.lowercased()),
                   backup != nil ? (event.side == "cloud" ? cloud != nil : local != nil)
                    : (local != nil && (copy != nil || cloud != nil)) {
                    Button(t("historyDiff")) { showLatexDiff(pair: pair, event: event) }
                        .disabled(filters.diffLoading)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
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
                            if let pair = pairForRecord(record) {
                                fileActions(pair, event: event)
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
                                            .disabled(!canRestore)
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
        .sheet(item: $filters.latexDiff) { result in
            LatexDiffSheet(result: result, language: language)
        }
    }
}
