import AppKit
import SwiftUI

private struct CloudImportPreviewSheet: View {
    let preview: CloudImportPreview
    let language: String
    let apply: () -> Void
    let cancel: () -> Void
    private func t(_ key: String) -> String { uiText(key, language: language) }

    private func schedule(_ config: SyncConfig) -> String {
        config.scheduleMode == "daily"
            ? String(format: "%02d:%02d", config.dailyHour, config.dailyMinute)
            : "\(config.intervalHours) \(t("hours"))"
    }

    private func ruleValue(_ key: String, config: SyncConfig) -> String {
        switch key {
        case "schedule": return schedule(config)
        case "conflict": return t(config.conflictPolicy == "keep-both" ? "autoKeepBoth" :
                                  config.conflictPolicy == "newest" ? "keepNewest" : "askForConflicts")
        case "backup": return "\(config.backupRetentionDays) \(t("days"))"
        default: return config.excludeLatexIntermediates ? t("enabled") : t("disabled")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("cloudPreviewTitle")).font(.title2.bold())
            Text(preview.profile.deviceName + " · " + String(preview.profile.effectivePairs.count) + " " + t("folders"))
                .foregroundStyle(.secondary)
            if preview.localEditsConflict {
                Label(t(preview.bothChanged ? "cloudRulesConflict" : "cloudLocalEdits"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(t("cloudPreviewHint")).font(.callout)
            if preview.changed.isEmpty && preview.ruleChanges.isEmpty && preview.preservedLocalPairs.isEmpty {
                Label(t("cloudNoChanges"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.ruleChanges, id: \.self) { key in
                        VStack(alignment: .leading) {
                            Text(t(key == "schedule" ? "schedule" : key == "conflict" ? "conflictHandling" :
                                   key == "backup" ? "backupRetention" : "latex")).font(.headline)
                            Text(ruleValue(key, config: preview.current) + " → " + ruleValue(key, config: preview.proposed))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                    ForEach(preview.changed) { pair in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pair.name).font(.headline)
                            if let before = preview.current.pairs.first(where: { $0.id == pair.id }),
                               before.scheduledDirection != pair.scheduledDirection {
                                Text(t("scheduledDirection") + ": " +
                                     t(before.scheduledDirection) + " → " + t(pair.scheduledDirection))
                            }
                            Text("\(t("local")): \(pair.localPath.isEmpty ? t("cloudUnset") : pair.localPath)")
                            Text("\(t("cloud")): \(pair.cloudPath.isEmpty ? t("cloudUnset") : pair.cloudPath)")
                            Text("Codex \(t(pair.syncCodexFiles ? "enabled" : "disabled")) · " +
                                 "Claude Code \(t(pair.syncClaudeFiles ? "enabled" : "disabled")) · " +
                                 "tmp \(t(pair.syncTemporaryFiles ? "enabled" : "disabled"))")
                            if !pair.enabled { Text(t("cloudPairDisabled")).foregroundStyle(.orange) }
                        }
                        .font(.caption)
                        .textSelection(.enabled)
                        Divider()
                    }
                    if !preview.preservedLocalPairs.isEmpty {
                        Text(t("cloudPreservedLocal")).font(.headline)
                        ForEach(preview.preservedLocalPairs) { pair in
                            Text(pair.name).font(.caption)
                        }
                    }
                    if !preview.localFoldersToCreate.isEmpty {
                        Text(t("cloudFoldersToCreate")).font(.headline)
                        ForEach(preview.localFoldersToCreate, id: \.self) {
                            Text($0).font(.caption).textSelection(.enabled)
                        }
                    }
                    if !preview.missingFolders.isEmpty {
                        Text(t("cloudMissingFolders")).font(.headline)
                        ForEach(preview.missingFolders, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            HStack {
                Spacer()
                Button(t("cancel"), action: cancel)
                Button(preview.localEditsConflict ? t("cloudUseRemoteRules") : t("cloudImport"), action: apply)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 680, height: 500)
    }
}


// Template glyph from the app icon: a pierced diamond.
func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        NSColor.black.set()
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: 8, y: 1.5))
        diamond.line(to: NSPoint(x: 14.5, y: 8))
        diamond.line(to: NSPoint(x: 8, y: 14.5))
        diamond.line(to: NSPoint(x: 1.5, y: 8))
        diamond.close()
        diamond.lineJoinStyle = .round
        diamond.lineWidth = 1
        diamond.fill()
        diamond.stroke()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: NSRect(x: 5.8, y: 5.8, width: 4.4, height: 4.4)).fill()
        return true
    }
    image.isTemplate = true
    return image
}

private func directionIcon(_ direction: String) -> String {
    switch direction {
    case "upload": return "icloud.and.arrow.up"
    case "download": return "icloud.and.arrow.down"
    default: return "arrow.left.arrow.right"
    }
}

private func abbreviatedPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

private let diffableExtensions: Set<String> = [
    "tex", "bib", "sty", "cls", "bst", "md", "markdown", "txt", "rtf", "csv", "tsv", "json", "yaml", "yml",
    "toml", "ini", "cfg", "py", "r", "m", "jl", "swift", "c", "h", "cpp", "hpp", "js", "ts", "html", "css",
    "sh", "zsh", "xml", "svg", "ipynb"
]

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .lineLimit(1)
    }
}

extension SyncModel {
    func t(_ key: String) -> String { uiText(key, language: config.language) }

    var displayLocale: Locale { Locale(identifier: usesEnglish(config.language) ? "en" : "zh-Hans") }

    func displayName(_ pair: SyncPair) -> String {
        pair.name.isEmpty ? t("unnamed") : pair.name
    }

    func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var scheduleSummary: String {
        if config.scheduleMode == "daily" {
            return "\(t("scheduleSummaryDaily")) \(String(format: "%02d:%02d", config.dailyHour, config.dailyMinute))"
        }
        return "\(t("scheduleSummaryInterval")) \(config.intervalHours) \(t("hours"))"
    }

    /// Next run of the saved schedule, or why there is none.
    var nextRunValue: String {
        guard savedConfig.enabled else { return t("scheduleOff") }
        guard savedConfig.scheduleMode == "daily" else { return scheduleSummary }
        var parts = DateComponents()
        parts.hour = savedConfig.dailyHour
        parts.minute = savedConfig.dailyMinute
        guard let next = Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime) else {
            return scheduleSummary
        }
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: next)
    }

    var enabledPairCount: Int { config.pairs.filter(\.enabled).count }

    /// "2 组启用 · 1 个冲突待处理 · 上次同步 16:05"
    var overviewSummary: String {
        var parts = [String(format: t("enabledCount"), enabledPairCount)]
        if conflictCount > 0 { parts.append(String(format: t("conflictCountShort"), conflictCount)) }
        parts.append(String(format: "%@ %@", t("lastSync"), lastSyncDate.map(shortDate) ?? t("never")))
        return parts.joined(separator: " · ")
    }

    var statusHeadline: String {
        if busy { return t(statusKey == "previewing" ? "previewing" : "syncing") }
        if conflictCount > 0 { return String(format: t("conflictCountShort"), conflictCount) }
        if !hasEnabledPairs { return t("menubarNoPairs") }
        return t("statusReady")
    }

    func pairStatus(_ pair: SyncPair) -> (text: String, color: Color) {
        if !pair.enabled { return (t("disabled"), .secondary) }
        if pair.localPath.isEmpty || pair.cloudPath.isEmpty { return (t("pairNotConfigured"), .secondary) }
        if busy && syncingPairIDs.contains(pair.id) {
            return (t(statusKey == "previewing" ? "previewing" : "pairSyncing"), .accentColor)
        }
        if let count = conflictsByPair[pair.id]?.count, count > 0 {
            return (String(format: t("pairConflictsShort"), count), .orange)
        }
        if let record = lastRecord(for: pair), record.hasFailures || record.finishedAt == nil {
            return (t("pairLastFailed"), .red)
        }
        return (lastRecord(for: pair) == nil ? t("pairOK") : t("pairSynced"), .green)
    }

    /// "已同步 · 16:05" for menu rows, "双向合并 · 上次同步 16:05" for cards.
    func pairDetail(_ pair: SyncPair) -> String {
        if busy, let progress = pairProgress[pair.id] { return progress }
        let status = pairStatus(pair).text
        guard pair.enabled, let date = lastSync(for: pair) else { return status }
        return "\(status) · \(shortDate(date))"
    }

    func pairFootnote(_ pair: SyncPair) -> String {
        let direction = t(pair.scheduledDirection)
        guard let date = lastSync(for: pair) else { return "\(direction) · \(t("lastSync")) \(t("never"))" }
        return "\(direction) · \(t("lastSync")) \(shortDate(date))"
    }

    var canRun: Bool { !busy && !hasUnsavedChanges }

    func canRun(_ pair: SyncPair) -> Bool {
        canRun && !pair.localPath.isEmpty && !pair.cloudPath.isEmpty
    }

    var resultBanner: String? {
        guard let counts = lastRunCounts, statusKey == "doneAll" || statusKey == "donePair" else { return nil }
        let parts = [("uploaded", "countUploaded"), ("downloaded", "countDownloaded"),
                     ("deleted", "countDeleted"), ("kept_both", "countKeptBoth"), ("failed", "countFailed")]
            .compactMap { key, text in counts[key, default: 0] > 0 ? String(format: t(text), counts[key]!) : nil }
        if parts.isEmpty { return t("resultNoChanges") }
        return String(format: t("resultBanner"), parts.joined(separator: usesEnglish(config.language) ? ", " : "，"))
    }

    /// Every pending conflict, grouped by folder pair in sidebar order.
    var allConflicts: [(pair: SyncPair, conflict: PendingConflict)] {
        config.pairs.flatMap { pair in (conflictsByPair[pair.id] ?? []).map { (pair, $0) } }
    }

    func canDiff(_ conflict: PendingConflict) -> Bool {
        !conflict.isTree && !conflict.localMissing && !conflict.cloudMissing
            && diffableExtensions.contains((conflict.name as NSString).pathExtension.lowercased())
    }

    /// Compares the main file with the preserved copy, or the local with the cloud version.
    func showDiff(_ conflict: PendingConflict, in pair: SyncPair) {
        let left = URL(fileURLWithPath: pair.localPath).appendingPathComponent(conflict.name)
        let right = conflict.sidecar.map { URL(fileURLWithPath: pair.localPath).appendingPathComponent($0) }
            ?? URL(fileURLWithPath: pair.cloudPath).appendingPathComponent(conflict.name)
        let leftTitle = conflict.sidecar == nil ? t("historyCurrentLocal") : t("viewMainFile")
        let rightTitle = conflict.sidecar ?? t("historyCurrentCloud")
        let language = config.language
        DispatchQueue.global(qos: .userInitiated).async {
            let result = makeLatexDiff(left: left, right: right, leftTitle: leftTitle,
                                       rightTitle: rightTitle, language: language)
            DispatchQueue.main.async { self.diffResult = result }
        }
    }
}

/// Planned changes of one folder pair, as rows of symbol, count and file names.
private struct PairPlanRows: View {
    let preview: PairPreview
    let model: SyncModel
    let compact: Bool

    private static let order: [(action: String, symbol: String, color: Color)] = [
        ("upload", "arrow.up.circle", .blue), ("download", "arrow.down.circle", .green),
        ("delete", "trash", .red), ("newest", "clock.arrow.circlepath", .purple),
        ("keep_both", "doc.on.doc", .orange), ("conflict", "exclamationmark.triangle", .orange),
        ("review", "hourglass", .orange), ("failed", "xmark.octagon", .red)
    ]

    private func t(_ key: String) -> String { model.t(key) }

    private func label(_ item: SyncPlanItem) -> String {
        guard item.action == "delete" else { return item.name }
        let side = t(item.side == "local" ? "planDeleteLocal" : "planDeleteCloud")
        return "\(item.name)（\(side)）"
    }

    private func names(_ items: [SyncPlanItem]) -> String {
        let limit = compact ? 2 : 6
        var text = items.prefix(limit).map(label).joined(separator: "、")
        if items.count > limit { text += " … " + String(format: t("previewMore"), items.count - limit) }
        return text
    }

    var body: some View {
        if let error = preview.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        } else if preview.isEmpty {
            Label(t("previewNoChanges"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                ForEach(Self.order, id: \.action) { row in
                    let items = preview.items(row.action)
                    if !items.isEmpty {
                        GridRow {
                            Label("\(t("plan_" + row.action)) \(items.count)", systemImage: row.symbol)
                                .foregroundStyle(row.color)
                                .lineLimit(1)
                                .fixedSize()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(names(items))
                                    .foregroundStyle(.primary)
                                    .lineLimit(compact ? 1 : 3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                if row.action == "delete" && !compact {
                                    Text(t("planBackedUp")).font(.caption).foregroundStyle(.secondary)
                                }
                                if !compact && items.count > 6 {
                                    DisclosureGroup(String(format: t("previewShowAll"), items.count)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                                Text(label(item)).font(.caption).textSelection(.enabled)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .font(compact ? .caption : .callout)
            if !compact, let skipped = preview.plan?.counts["skipped"], skipped > 0 {
                Text(String(format: t("previewSkipped"), skipped))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The confirmation sheet in the main window. Confirming runs the same scope.
struct SyncPreviewSheet: View {
    @ObservedObject var model: SyncModel
    let preview: SyncPreview
    @Environment(\.dismiss) private var dismiss

    private func t(_ key: String) -> String { model.t(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("previewTitle")).font(.title2.bold())
                Text(t("previewHint")).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(preview.pairs) { pair in
                        GroupBox {
                            PairPlanRows(preview: pair, model: model, compact: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                        } label: {
                            Text("\(pair.pairName) · \(t(pair.direction))").font(.headline)
                        }
                    }
                }
            }
            HStack {
                Text(String(format: t("previewMade"), model.shortDate(preview.createdAt)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(t("cancel")) {
                    model.preview = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(t("previewConfirm")) {
                    model.confirmPreview()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun || preview.pairs.allSatisfy { $0.error != nil })
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
    }
}

/// One pending conflict with the quick actions that fit it.
struct ConflictRow: View {
    @ObservedObject var model: SyncModel
    let pair: SyncPair
    let conflict: PendingConflict
    let compact: Bool
    var showsPairName = true

    private func t(_ key: String) -> String { model.t(key) }

    private var kindText: String {
        if conflict.isTree { return t("conflictKindTree") }
        if conflict.isReview { return t("conflictKindReview") }
        if conflict.localMissing || conflict.cloudMissing { return t("conflictKindDelete") }
        return t("conflictKindPending")
    }

    private func reveal(_ root: String, _ name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(name)])
    }

    private var blocked: Bool { conflict.blockedByTree != nil }

    @ViewBuilder
    private var locateMenu: some View {
        Menu {
            if conflict.isTree {
                Button(t("viewLocal")) { reveal(pair.localPath, conflict.name) }
                Button(t("viewCloud")) { reveal(pair.cloudPath, conflict.name) }
            } else if let sidecar = conflict.sidecar {
                Button(t("viewMainFile")) { reveal(pair.localPath, conflict.name) }
                Button(t("viewReviewCopy")) { reveal(pair.localPath, sidecar) }
            } else {
                Button(t("viewLocal")) { reveal(pair.localPath, conflict.name) }
                    .disabled(conflict.localMissing)
                Button(t("viewCloud")) { reveal(pair.cloudPath, conflict.name) }
                    .disabled(conflict.cloudMissing)
            }
        } label: {
            if conflict.isTree { Text(t("showInFinder")) } else { Image(systemName: "folder") }
        }
        .help(t("showInFinder"))
        .fixedSize()
    }

    @ViewBuilder
    private var actions: some View {
        if conflict.isTree {
            locateMenu
        } else if conflict.isReview {
            if model.canDiff(conflict) {
                Button(t("viewDiff")) { model.showDiff(conflict, in: pair) }
            }
            Button(t("useNewerShort")) { model.chooseNewestForReview(conflict.name, in: pair) }
                .disabled(model.busy || blocked)
                .help(t("chooseNewest"))
            Button(compact ? t("markReviewedShort") : t("confirmReviewed")) {
                model.acknowledgeConflict(conflict.name, in: pair)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || blocked)
            locateMenu
        } else {
            if model.canDiff(conflict) {
                Button(t("viewDiff")) { model.showDiff(conflict, in: pair) }
            }
            Menu(t("resolve")) {
                Button(conflict.localMissing ? t("keepDeletion") : t("useLocal")) {
                    model.resolveConflict(conflict.name, choice: "local", in: pair)
                }
                Button(conflict.cloudMissing ? t("keepDeletion") : t("useCloud")) {
                    model.resolveConflict(conflict.name, choice: "cloud", in: pair)
                }
                if !conflict.localMissing && !conflict.cloudMissing {
                    Button(t("chooseNewest")) { model.resolveConflict(conflict.name, choice: "newest", in: pair) }
                    Button(t("keepBoth")) { model.resolveConflict(conflict.name, choice: "both", in: pair) }
                }
            }
            .fixedSize()
            .disabled(!model.canRun || blocked)
            locateMenu
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: conflict.isTree ? "folder.badge.questionmark" : "doc.on.doc")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.name)
                        .fontWeight(.semibold)
                        .lineLimit(compact ? 1 : 2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(showsPairName ? "\(model.displayName(pair)) · \(kindText)" : kindText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if blocked {
                        Text(t("childBlockedByTree")).font(.caption).foregroundStyle(.orange)
                    }
                }
                if !compact {
                    Spacer(minLength: 12)
                    HStack(spacing: 6) { actions }
                        .controlSize(.small)
                }
            }
            if compact {
                HStack(spacing: 6) { actions }
                    .controlSize(.small)
            }
        }
    }
}

/// The menu bar panel: status at a glance and one action. Everything else opens the window.
struct MenuBarPanel: View {
    @ObservedObject var model: SyncModel
    @Environment(\.openWindow) private var openWindow

    private func t(_ key: String) -> String { model.t(key) }

    private func showWindow(_ page: String) {
        model.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A running sync, an error or the last result replaces the schedule lines.
    private var statusMessage: String? {
        if model.busy, let detail = model.statusDetail { return detail }
        if model.statusKey == "error", let detail = model.statusDetail { return detail }
        return model.resultBanner
    }

    private var headline: String {
        if !model.busy && model.statusKey != "error" && model.conflictCount > 0 { return t("attentionNeeded") }
        return model.statusHeadline
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if model.busy {
                    ProgressView().controlSize(.small)
                } else if model.statusKey == "error" {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                } else if model.conflictCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.title2)
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.headline).lineLimit(1)
                Group {
                    if let message = statusMessage {
                        Text(message).lineLimit(2)
                    } else {
                        Text("\(t("lastSync"))：\(model.lastSyncDate.map(model.shortDate) ?? t("never"))")
                            .lineLimit(1)
                        Text("\(t("nextSync"))：\(model.nextRunValue)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.syncNow(all: true) } label: {
                Label(t("syncNow"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canRun || !model.hasEnabledPairs)
            .help(t("syncAllHint"))
        }
    }

    private func pairRow(_ pair: SyncPair) -> some View {
        let status = model.pairStatus(pair)
        let detail: String = {
            if model.busy, let progress = model.pairProgress[pair.id] { return progress }
            if !pair.enabled { return status.text }
            return model.lastSync(for: pair).map(model.shortDate) ?? t("never")
        }()
        return HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(status.color)
                .help(status.text)
            Text(model.displayName(pair))
                .foregroundStyle(pair.enabled ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func menuRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.vertical, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if model.config.pairs.isEmpty {
                    Text(t("menubarNoPairs")).foregroundStyle(.secondary)
                }
                ForEach(model.config.pairs) { pair in pairRow(pair) }
            }
            if model.conflictCount > 0 {
                Button { showWindow("overview") } label: {
                    HStack {
                        Label(String(format: t("conflictCountShort"), model.conflictCount),
                              systemImage: "exclamationmark.triangle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .foregroundStyle(.orange)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            if let release = model.availableRelease {
                Button(String(format: t("menubarUpdate"), release.version)) { showWindow("settings") }
                    .buttonStyle(.link)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                menuRow(t("openMainWindow"), systemImage: "macwindow") { showWindow("overview") }
                menuRow(t("history"), systemImage: "clock.arrow.circlepath") { showWindow("history") }
                menuRow(t("menubarQuit"), systemImage: "power") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct ContentView: View {
    @ObservedObject var model: SyncModel

    private func t(_ key: String) -> String { model.t(key) }

    private var selectedRoute: Binding<String?> {
        Binding(get: {
            if model.page == "pair", let id = model.selectedID { return "pair:\(id.uuidString)" }
            return model.page == "about" ? "settings" : model.page
        }, set: { route in
            guard let route else { return }
            if route.hasPrefix("pair:"), let id = UUID(uuidString: String(route.dropFirst(5))) {
                model.selectedID = id
                model.page = "pair"
            } else {
                model.page = route
            }
        })
    }

    private var windowPreview: Binding<SyncPreview?> {
        Binding(get: { model.previewOrigin == "window" ? model.preview : nil },
                set: { if $0 == nil && model.previewOrigin == "window" { model.preview = nil } })
    }

    private var pageTitle: String {
        switch model.page {
        case "history": return t("history")
        case "settings", "about": return t("settings")
        case "pair": return model.selectedPair.map { model.displayName($0) } ?? t("folders")
        default: return t("overview")
        }
    }

    private func openPair(_ pair: SyncPair) {
        model.selectedID = pair.id
        model.page = "pair"
    }

    // MARK: - Layout

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(pageTitle)
                .toolbar { toolbarContent }
        }
        .frame(minWidth: 860, minHeight: 580)
        .environment(\.locale, model.config.language == "system" ? .current : Locale(identifier: model.config.language))
        .confirmationDialog(String(format: t("removeConfirm"), model.selectedPair.map { model.displayName($0) } ?? ""),
                            isPresented: $model.confirmingRemoval) {
            Button(t("removeFolder"), role: .destructive) { model.removeSelected() }
        } message: {
            Text(t("removeConfirmHint"))
        }
        .sheet(item: $model.cloudImportPreview) { preview in
            CloudImportPreviewSheet(preview: preview, language: model.config.language,
                apply: { model.applyCloudImport(preview) }, cancel: { model.cloudImportPreview = nil })
        }
        .background {
            // Separate anchors so the preview and diff sheets never replace each other.
            Color.clear.sheet(item: windowPreview) { preview in
                SyncPreviewSheet(model: model, preview: preview)
            }
            Color.clear.sheet(item: $model.diffResult) { result in
                LatexDiffSheet(result: result, language: model.config.language)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshState()
            model.refreshCloudProfiles()
        }
    }

    private var sidebar: some View {
        List(selection: selectedRoute) {
            Label(t("overview"), systemImage: "square.grid.2x2")
                .badge(model.conflictCount)
                .tag("overview")
            Label(t("history"), systemImage: "clock.arrow.circlepath")
                .tag("history")
            Label(t("settings"), systemImage: "gearshape")
                .badge(model.availableRelease == nil ? nil : Text(t("updateBadge")))
                .tag("settings")
            Section(t("folders")) {
                ForEach(model.config.pairs) { pair in
                    Label {
                        Text(model.displayName(pair))
                            .foregroundStyle(pair.enabled ? Color.primary : Color.secondary)
                    } icon: {
                        Image(systemName: directionIcon(pair.scheduledDirection))
                            .foregroundStyle(model.pairStatus(pair).color)
                    }
                    .badge(model.conflictsByPair[pair.id]?.count ?? 0)
                    .tag("pair:\(pair.id.uuidString)")
                    .help(model.pairStatus(pair).text)
                    .contextMenu {
                        Button(t("previewPair")) { model.previewNow(pairID: pair.id) }
                            .disabled(!model.canRun(pair))
                        Button(t("syncPairNow")) { model.syncNow(pairID: pair.id) }
                            .disabled(!model.canRun(pair))
                        Divider()
                        Button(t("removeFolder") + "…") {
                            openPair(pair)
                            model.confirmingRemoval = true
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button { model.addPair() } label: {
                    Label(t("addFolder"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                Label("\(t("nextSync"))：\(model.nextRunValue)", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.page == "pair", let pair = model.selectedPair {
                Button { model.previewNow(pairID: pair.id) } label: {
                    Label(t("previewPair"), systemImage: "eye")
                }
                .help(t("previewHint"))
                .disabled(!model.canRun(pair))
                Button { model.syncNow(pairID: pair.id) } label: {
                    Label(t("syncPairNow"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(t("syncPairHint"))
                .disabled(!model.canRun(pair))
            } else {
                Button { model.previewNow() } label: {
                    Label(t("previewAll"), systemImage: "eye")
                }
                .help(t("previewHint"))
                .disabled(!model.canRun || !model.hasEnabledPairs)
                Button { model.syncNow(all: true) } label: {
                    Label(t("syncAllNow"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(t("syncAllHint"))
                .disabled(!model.canRun || !model.hasEnabledPairs)
            }
            Button { model.save() } label: {
                Label(t("save"), systemImage: "checkmark.circle")
            }
            .help(model.hasUnsavedChanges ? t("unsaved") : t("save"))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.busy)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case "settings", "about":
            settingsForm
        case "history":
            HistoryPage(records: model.history, pairs: model.config.pairs,
                        language: model.config.language, backupConfig: model.savedConfig,
                        error: model.historyError,
                        refresh: model.refreshHistory,
                        restore: { pair, id in model.restoreBackup(pair: pair, id: id) },
                        canRestore: !model.hasUnsavedChanges && !model.busy)
        case "pair":
            if let index = model.selectedIndex {
                pairPage(index)
            } else {
                emptyState
            }
        default:
            overview
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus").font(.system(size: 40))
            Text(t("empty"))
            Button(t("addFolder")) { model.addPair() }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else if model.statusKey == "error" {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else if model.conflictCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
            Text(model.statusDetail ?? t(model.statusKey))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.statusDetail ?? t(model.statusKey))
            Spacer()
            if model.hasUnsavedChanges {
                Circle().fill(.orange).frame(width: 6, height: 6)
                Text(t("unsaved"))
                Button(t("save")) { model.save() }
                    .controlSize(.small)
                    .disabled(model.busy)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewHeader
                if let banner = model.resultBanner {
                    Label(banner, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
                }
                if let release = model.availableRelease { updateBanner(release) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(model.config.pairs) { pair in pairCard(pair) }
                }
                if model.config.pairs.isEmpty { emptyState.frame(height: 200) }
                pendingSection
            }
            .padding(24)
        }
    }

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if model.busy {
                    ProgressView()
                } else if model.statusKey == "error" {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                } else if model.conflictCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if !model.hasEnabledPairs {
                    Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.system(size: 30))
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.statusHeadline).font(.title2.weight(.semibold))
                Text(model.busy ? (model.statusDetail ?? model.overviewSummary) : model.overviewSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button { model.previewNow() } label: {
                Label(t("previewAll"), systemImage: "eye")
            }
            .controlSize(.large)
            .disabled(!model.canRun || !model.hasEnabledPairs)
            Button { model.syncNow(all: true) } label: {
                Label(t("syncNow"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canRun || !model.hasEnabledPairs)
        }
    }

    private func updateBanner(_ release: AppRelease) -> some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: t("updateAvailable"), release.version)).font(.headline)
                    Text(t(release.signatureURL == nil ? "updateManualHint" : "updateInstallHint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(t("updateDetails")) { model.page = "settings" }
                if release.signatureURL != nil {
                    Button(t("updateInstall")) { model.installAvailableUpdate() }
                        .disabled(model.busy || model.hasUnsavedChanges || model.updateInstallBusy)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(t("updateDownload")) { NSWorkspace.shared.open(release.downloadURL ?? release.pageURL) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(4)
        }
    }

    private func pathLine(_ icon: String, _ path: String) -> some View {
        Label {
            Text(path.isEmpty ? t("folderNotChosen") : abbreviatedPath(path))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        } icon: {
            Image(systemName: icon)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func pairCard(_ pair: SyncPair) -> some View {
        let status = model.pairStatus(pair)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(model.displayName(pair)).font(.headline).lineLimit(1)
                    StatusBadge(text: t(pair.scheduledDirection), color: .accentColor)
                    Spacer(minLength: 8)
                    Label(status.text, systemImage: "circle.fill")
                        .labelStyle(StatusDotLabelStyle(color: status.color))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(status.color == .secondary ? Color.secondary : status.color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    pathLine("laptopcomputer", pair.localPath)
                    pathLine("cloud", pair.cloudPath)
                }
                HStack(spacing: 8) {
                    Text(model.busy && model.pairProgress[pair.id] != nil
                         ? model.pairProgress[pair.id]! : model.pairFootnote(pair))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(t("editPair")) { openPair(pair) }
                        .buttonStyle(.borderless)
                    Button(t("preview")) { model.previewNow(pairID: pair.id) }
                        .disabled(!model.canRun(pair))
                    Button(t("syncShort")) { model.syncNow(pairID: pair.id) }
                        .disabled(!model.canRun(pair))
                }
                .controlSize(.small)
            }
            .padding(4)
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("pendingTitle")).font(.headline)
                Spacer()
                Button { model.refreshConflicts() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(t("refreshConflicts"))
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    let conflicts = model.allConflicts
                    if conflicts.isEmpty {
                        Label(t("noPending"), systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    ForEach(Array(conflicts.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider() }
                        ConflictRow(model: model, pair: item.pair, conflict: item.conflict, compact: false)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.allConflicts.contains(where: { $0.conflict.isReview }) {
                Text(t("conflictHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Folder pair

    private func pairPage(_ index: Int) -> some View {
        let pair = model.config.pairs[index]
        let conflicts = model.conflictsByPair[pair.id] ?? []
        return Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(pair.enabled ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(t("name"), text: $model.config.pairs[index].name,
                                  prompt: Text(t("namePlaceholder")))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                        Text(model.pairFootnote(pair)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle(isOn: $model.config.pairs[index].enabled) { Text(t("enabledShort")) }
                        .toggleStyle(.switch)
                        .help(t("pairEnabled"))
                }
                .padding(.vertical, 4)
            }

            Section {
                folderRow(t("local"), icon: "laptopcomputer", path: $model.config.pairs[index].localPath) {
                    model.chooseFolder(local: true)
                }
                folderRow(t("cloud"), icon: "cloud", path: $model.config.pairs[index].cloudPath) {
                    model.chooseFolder(local: false)
                }
            } header: {
                Text(t("folders"))
            } footer: {
                Text(t("pairSubtitle"))
            }

            Section {
                Picker(t("direction"), selection: $model.config.pairs[index].scheduledDirection) {
                    Text(t("merge")).tag("merge")
                    Text(t("upload")).tag("upload")
                    Text(t("download")).tag("download")
                }
                .pickerStyle(.segmented)
                LabeledContent(t("usingSchedule")) {
                    Button(model.scheduleSummary) { model.page = "settings" }
                        .buttonStyle(.link)
                }
                LabeledContent(t("runNow")) {
                    HStack(spacing: 8) {
                        Menu(t("syncOnceIn")) {
                            Button(t("merge")) { model.syncNow(.merge, pairID: pair.id) }
                            Button(t("upload")) { model.syncNow(.upload, pairID: pair.id) }
                            Button(t("download")) { model.syncNow(.download, pairID: pair.id) }
                        }
                        .fixedSize()
                        Button { model.previewNow(pairID: pair.id) } label: {
                            Label(t("preview"), systemImage: "eye")
                        }
                        Button { model.syncNow(pairID: pair.id) } label: {
                            Label(t("syncNow"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(!model.canRun(pair))
                }
            } header: {
                Text(t("directionSection"))
            } footer: {
                Text(t(model.config.conflictPolicy == "keep-both" ? "directionHintAuto" :
                       (model.config.conflictPolicy == "newest" ? "directionHintNewest" : "directionHintAsk")))
            }

            Section {
                Toggle(t("syncCodexFiles"), isOn: $model.config.pairs[index].syncCodexFiles)
                Toggle(t("syncClaudeFiles"), isOn: $model.config.pairs[index].syncClaudeFiles)
                Toggle(t("syncTemporaryFiles"), isOn: $model.config.pairs[index].syncTemporaryFiles)
            } header: {
                Text(t("pairFilters"))
            } footer: {
                Text(t("pairFiltersHint"))
            }

            Section {
                if conflicts.isEmpty {
                    Label(t("noConflicts"), systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(conflicts) { conflict in
                        ConflictRow(model: model, pair: pair, conflict: conflict, compact: false, showsPairName: false)
                            .padding(.vertical, 4)
                    }
                }
            } header: {
                HStack {
                    Text(t("conflicts"))
                    if !conflicts.isEmpty { StatusBadge(text: "\(conflicts.count)", color: .orange) }
                    Spacer()
                    Button { model.refreshConflicts() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(t("refreshConflicts"))
                }
            } footer: {
                if conflicts.contains(where: \.isReview) { Text(t("conflictHint")) }
            }

            Section {
                Button(role: .destructive) { model.confirmingRemoval = true } label: {
                    Label(t("removeFolder") + "…", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func folderRow(_ title: String, icon: String, path: Binding<String>,
                           choose: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, text: path, prompt: Text(t("chooseFolder")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 240)
                Button(t("browse"), action: choose)
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path.wrappedValue))
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help(t("revealInFinder"))
                .disabled(path.wrappedValue.isEmpty)
            }
        } label: {
            Label(title, systemImage: icon)
        }
    }

    // MARK: - Settings

    private var dailyTime: Binding<Date> {
        Binding(get: {
            var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            parts.hour = model.config.dailyHour
            parts.minute = model.config.dailyMinute
            return Calendar.current.date(from: parts) ?? Date()
        }, set: { value in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            model.config.dailyHour = parts.hour ?? 23
            model.config.dailyMinute = parts.minute ?? 0
        })
    }

    private var settingsForm: some View {
        Form {
            Section {
                Toggle(t("background"), isOn: $model.config.enabled)
                Group {
                    Picker(t("runMode"), selection: $model.config.scheduleMode) {
                        Text(t("daily")).tag("daily")
                        Text(t("interval")).tag("interval")
                    }
                    .pickerStyle(.segmented)
                    if model.config.scheduleMode == "daily" {
                        DatePicker(t("runTime"), selection: dailyTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                    } else {
                        Stepper(value: $model.config.intervalHours, in: 6...168) {
                            LabeledContent(t("intervalHours"), value: "\(model.config.intervalHours) \(t("hours"))")
                        }
                    }
                }
                .disabled(!model.config.enabled)
            } header: {
                Text(t("schedule"))
            } footer: {
                Text(t("backgroundHint") + " "
                     + (model.config.scheduleMode == "daily" ? t("dailyHint") : t("atLeastSix")))
            }

            Section {
                Picker(t("conflictHandling"), selection: $model.config.conflictPolicy) {
                    Text(t("autoKeepBoth")).tag("keep-both")
                    Text(t("askForConflicts")).tag("ask")
                    Text(t("keepNewest")).tag("newest")
                }
                .pickerStyle(.menu)
                Stepper(value: $model.config.backupRetentionDays, in: 1...365) {
                    LabeledContent(t("backupRetention"),
                                   value: "\(model.config.backupRetentionDays) \(t("days"))")
                }
                backupLocationRows
            } header: {
                Text(t("conflictsAndBackups"))
            } footer: {
                Text(t("conflictPolicyHint") + " " + t("backupHint"))
            }

            Section {
                Toggle(t("latex"), isOn: $model.config.excludeLatexIntermediates)
            } header: {
                Text(t("filterTitle"))
            } footer: {
                Text(t("filterHint"))
            }

            Section {
                Picker(t("notifications"), selection: Binding(
                    get: { model.config.notificationMode },
                    set: { model.chooseNotificationMode($0) }
                )) {
                    Text(t("notificationsOff")).tag("off")
                    Text(t("notificationsIssues")).tag("issues")
                    Text(t("notificationsAll")).tag("all")
                }
                .pickerStyle(.menu)
                Picker(t("language"), selection: $model.config.language) {
                    Text(t("systemLanguage")).tag("system")
                    Text(t("chinese")).tag("zh-Hans")
                    Text(t("english")).tag("en")
                }
                .pickerStyle(.menu)
                Toggle(t("launchAtLogin"), isOn: Binding(
                    get: { model.launchAtLoginStatus == .enabled || model.launchAtLoginStatus == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if model.launchAtLoginStatus == .requiresApproval {
                    Label(t("launchAtLoginApproval"), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if let error = model.launchAtLoginError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(t("general"))
            } footer: {
                Text(t("notificationHint"))
            }

            updatesSection
            cloudConfigSection
            configRollbackSection
            aboutSection
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshLaunchAtLogin()
            model.refreshLocalBackupSize()
        }
    }

    @ViewBuilder
    private var backupLocationRows: some View {
        Picker(t("backupLocation"), selection: $model.config.backupLocation) {
            Label(t("backupLocal"), systemImage: "laptopcomputer").tag("local")
            Label(t("backupICloud"), systemImage: "icloud").tag("icloud")
            Label(t("backupFolderOption"), systemImage: "folder").tag("folder")
        }
        .pickerStyle(.menu)
        if model.config.backupLocation == "folder" {
            LabeledContent(t("backupFolderOption")) {
                Text(model.config.backupFolder.isEmpty ? t("backupFolderMissing") : abbreviatedPath(model.config.backupFolder))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(model.config.backupFolder.isEmpty ? Color.orange : Color.secondary)
                    .help(model.config.backupFolder)
                Button(t("backupFolderChoose")) { model.chooseBackupFolder() }
            }
        } else if let folder = model.config.backupDisplayFolder {
            LabeledContent(t("backupICloud")) {
                Text(abbreviatedPath(folder)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
        }
        if model.config.backupLocation != "local" {
            Text(t("backupLocationHint")).font(.caption).foregroundStyle(.secondary)
        }
        if model.savedConfig.backupBaseFolder != nil {
            HStack {
                Button {
                    model.moveExistingBackups()
                } label: {
                    if let size = model.localBackupSize, size > 0 {
                        Text(String(format: t("backupMoveSize"),
                                    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
                    } else {
                        Text(t("backupMove"))
                    }
                }
                .disabled(model.hasUnsavedChanges || model.busy || model.backupMoveBusy || model.localBackupSize == 0)
                if model.backupMoveBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if model.hasUnsavedChanges {
                Text(t("backupMoveNeedsSave")).font(.caption).foregroundStyle(.secondary)
            } else if let message = model.backupMoveMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if model.localBackupSize == 0 {
                Text(t("backupNoneLocal")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var updatesSection: some View {
            Section {
                HStack(spacing: 10) {
                    updateStatusIcon.frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateStatusText)
                        Text(lastCheckedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let release = model.availableRelease {
                        if let downloadURL = release.downloadURL {
                            Button(t("updateReleaseNotes")) { NSWorkspace.shared.open(release.pageURL) }
                            if release.signatureURL != nil {
                                Button(t("updateInstall")) { model.installAvailableUpdate() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.busy || model.hasUnsavedChanges || model.updateInstallBusy)
                            } else {
                                Button(t("updateDownload")) { NSWorkspace.shared.open(downloadURL) }
                                    .buttonStyle(.borderedProminent)
                            }
                        } else {
                            Button(t("updateReleaseNotes")) { NSWorkspace.shared.open(release.pageURL) }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button(t("checkForUpdatesButton")) { model.checkForUpdates() }
                            .disabled(model.update == .checking)
                    }
                }
                if let release = model.availableRelease {
                    if !release.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                                Text("• " + note)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    switch model.updateInstallPhase {
                    case .downloading: Label(t("updateDownloading"), systemImage: "arrow.down.circle")
                    case .verifying: Label(t("updateVerifying"), systemImage: "checkmark.shield")
                    case .replacing: Label(t("updateReplacing"), systemImage: "arrow.triangle.2.circlepath")
                    case .failed(let message): Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    case .idle: EmptyView()
                    }
                    Text(t(release.signatureURL == nil ? "updateManualHint" : "updateInstallHint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(t("updateScopeHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(t("autoCheckUpdates"), isOn: $model.config.checkForUpdates)
                Toggle(t("autoInstallUpdates"), isOn: Binding(
                    get: { model.config.autoInstallUpdates },
                    set: { enabled in
                        model.config.autoInstallUpdates = enabled
                        if enabled { model.config.checkForUpdates = true }
                    }))
            } header: {
                Text(t("updates"))
            } footer: {
                Text(t("autoCheckHint"))
            }
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("appName")).font(.headline)
                    Text("\(t("version")) \(model.currentVersion)").foregroundStyle(.secondary)
                    Text(t("aboutSubtitle")).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent(t("source")) {
                Link("github.com/ensomnia16/PathSync", destination: URL(string: "https://github.com/ensomnia16/PathSync")!)
            }
            LabeledContent(t("author")) {
                Link("ensomnia16", destination: URL(string: "https://github.com/ensomnia16")!)
            }
        } header: {
            Text(t("about"))
        }
    }

    private func relativeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = model.displayLocale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - About and updates

    private var updateStatusText: String {
        switch model.update {
        case .idle: return t("updateNotChecked")
        case .checking: return t("updateChecking")
        case .upToDate(let release): return String(format: t("updateUpToDate"), release.version)
        case .aheadOfRelease(let release): return String(format: t("updateAheadOfRelease"),
                                                          model.currentVersion, release.version)
        case .failed: return t("updateFailed")
        case .available(let release): return String(format: t("updateAvailable"), release.version)
        }
    }

    @ViewBuilder
    private var updateStatusIcon: some View {
        switch model.update {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .aheadOfRelease: Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .available: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .idle: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var lastCheckedText: String {
        guard let checked = model.lastUpdateCheck else {
            return "\(t("updateLastChecked")) \(t("never"))"
        }
        let when = abs(Date().timeIntervalSince(checked)) < 60 ? t("justNow") : relativeText(checked)
        return "\(t("updateLastChecked")) \(when)"
    }


    private var cloudConfigSection: some View {
            Section {
                Toggle(t("cloudConfigEnable"), isOn: $model.config.cloudConfigEnabled)
                if model.config.cloudConfigEnabled {
                    LabeledContent(t("localRoot")) {
                        Text(abbreviatedPath(model.config.localRoot))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .help(model.config.localRoot)
                        Button(t("chooseLocalRoot")) { model.chooseLocalRoot() }
                    }
                    LabeledContent(t("oneDriveRoot")) {
                        Text(model.config.oneDriveRoot.isEmpty ? "—" : abbreviatedPath(model.config.oneDriveRoot))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(model.config.oneDriveRoot)
                        Button(t("chooseOneDriveRoot")) { model.chooseOneDriveRoot() }
                    }
                    let count = model.config.pairs.filter {
                        !$0.cloudPath.isEmpty &&
                        relativePath($0.cloudPath, within: model.config.oneDriveRoot) == nil
                    }.count
                    if count > 0 {
                        Label(String(format: t("cloudNoRelative"), count), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Text(t("cloudProfiles")).font(.headline)
                        Spacer()
                        if model.cloudBusy { ProgressView().controlSize(.small) }
                        Button(t("cloudRefresh")) { model.refreshCloudProfiles() }
                            .disabled(model.cloudBusy)
                    }
                    if let own = model.ownCloudProfile {
                        LabeledContent(t("cloudThisDevice")) {
                            Text(own.deviceName)
                            Text(t("cloudTransfer_" + model.ownCloudTransferStatus))
                                .foregroundStyle(model.ownCloudTransferStatus == "error" ? Color.orange : Color.secondary)
                        }
                    }
                    if model.cloudProfiles.isEmpty && !model.cloudBusy {
                        Text(t("cloudNone")).foregroundStyle(.secondary)
                    }
                    ForEach(model.cloudProfiles) { profile in cloudProfileRow(profile) }
                    if let error = model.cloudError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if model.lastCloudPublish != nil {
                        Label(t("cloudPublished"), systemImage: "checkmark.icloud")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("cloudConfig"))
            } footer: {
                Text(cloudConfigFooter)
            }


    }

    private var configRollbackSection: some View {
            Section {
                if model.configBackups.isEmpty {
                    Text(t("configNoBackups")).foregroundStyle(.secondary)
                }
                ForEach(model.configBackups.prefix(5)) { snapshot in
                    HStack {
                        Text(snapshot.date, style: .date)
                        Text(snapshot.date, style: .time).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("configLoadBackup")) { model.restoreConfigSnapshot(snapshot) }
                    }
                }
            } header: {
                Text(t("configRollback"))
            } footer: {
                Text(t("configRollbackHint"))
            }
    }

    private var cloudConfigFooter: String {
        ["cloudConfigHint", "oneDriveRootHint", "cloudImportHint"].map(t).joined(separator: " ")
    }

    private func cloudProfileRow(_ profile: CloudConfiguration) -> some View {
        let anchor = model.config.cloudImportAnchors[profile.deviceID.uuidString.lowercased()]
        let applied = anchor?.revisionID == profile.revisionID
        let peerImportedOwn = model.ownCloudProfile.flatMap { own in
            profile.importedRevisions?[own.deviceID.uuidString.lowercased()] == own.revisionID
        } ?? false
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.deviceName)
                Text(profile.modifiedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                Text(anchor == nil ? t("cloudRevisionNever") :
                     t(applied ? "cloudRevisionApplied" : "cloudRevisionNew"))
                    .font(.caption)
                    .foregroundStyle(applied || anchor == nil ? Color.secondary : Color.orange)
                Text(peerImportedOwn ? t("cloudPeerImported") : t("cloudPeerUnconfirmed"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(profile.effectivePairs.count) \(t("folders"))").foregroundStyle(.secondary)
            Button(t("cloudImport")) { model.importCloudProfile(profile) }
                .disabled(model.hasUnsavedChanges || model.busy)
        }
    }
}

/// A small coloured dot before a status text.
private struct StatusDotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 7))
                .foregroundStyle(color)
            configuration.title
        }
    }
}
