import AppKit
import SwiftUI

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

    var canRun: Bool { !isSyncActive && !hasUnsavedChanges }

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
        ("review", "hourglass", .orange), ("online", "icloud.and.arrow.down", .teal),
        ("skip", "arrow.right.circle", .secondary), ("failed", "xmark.octagon", .red)
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
            if let online = preview.plan?.counts["online_only"], online > 0 {
                Label(String(format: t("previewOnline"), online), systemImage: "icloud.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

struct MenuBarPanel: View {
    @ObservedObject var model: SyncModel
    var closeMenuBar: () -> Void = {}

    private func t(_ key: String) -> String { model.t(key) }

    private func showWindow(_ page: String, pair: SyncPair? = nil) {
        if let pair { model.selectedID = pair.id }
        model.page = page
        closeMenuBar()
        NSApp.setActivationPolicy(.regular)
        URLCommandRouter.openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusColor: Color {
        if model.isSyncActive { return .accentColor }
        if model.statusKey == "error" { return .red }
        if model.conflictCount > 0 { return .orange }
        return model.menuBarState == .enabled ? .green : .secondary
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(t("appName")).font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(t(model.menuBarState.titleKey))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { showWindow("settings") } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain).help(t("settings")).accessibilityLabel(t("settings"))
        }
    }

    private func summaryItem(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var primaryAction: some View {
        Button { model.syncNow(all: true) } label: {
            HStack(spacing: 7) {
                if model.isSyncActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(t(model.isSyncActive ? "syncing" : "syncNow")).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(!model.canRun || !model.hasEnabledPairs)
        .help(t("syncAllHint"))
    }

    private func pairRow(_ pair: SyncPair) -> some View {
        let status = model.pairStatus(pair)
        return Button { showWindow("pair", pair: pair) } label: {
            HStack(spacing: 9) {
                Image(systemName: pair.enabled ? "folder.fill" : "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(pair.enabled ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName(pair)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(t(pair.scheduledDirection)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(status.text).font(.system(size: 10, weight: .medium)).foregroundStyle(status.color)
                    if pair.enabled, let date = model.lastSync(for: pair) {
                        Text(model.shortDate(date)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 53)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .accessibilityLabel(model.displayName(pair) + ", " + status.text)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("folders")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: t("enabledCount"), model.enabledPairCount))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.config.pairs.isEmpty {
                Text(t("menubarNoPairs")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.config.pairs) { pair in
                            pairRow(pair)
                            if pair.id != model.config.pairs.last?.id { Divider().padding(.leading, 49) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: CGFloat(min(model.config.pairs.count, 5)) * 54 - 1)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.65),
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }

    @ViewBuilder private var notice: some View {
        if model.hasUnsavedChanges {
            Button { showWindow("overview") } label: {
                Label(t("menubarSaveHint"), systemImage: "pencil.circle")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
        } else if model.conflictCount > 0 {
            Button { showWindow("overview") } label: {
                Label(String(format: t("conflictCountShort"), model.conflictCount),
                      systemImage: "exclamationmark.triangle.fill")
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
        } else if let detail = model.statusDetail, model.busy || model.statusKey == "error" {
            Text(detail).font(.caption).foregroundStyle(model.statusKey == "error" ? Color.red : Color.secondary)
                .lineLimit(2)
        } else if let result = model.resultBanner {
            Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { showWindow("overview") } label: {
                Label(t("openMainWindow"), systemImage: "macwindow")
            }
            Spacer(minLength: 0)
            Button { showWindow("history") } label: {
                Image(systemName: "clock.arrow.circlepath")
            }.help(t("history")).accessibilityLabel(t("history"))
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }.help(t("menubarQuit")).accessibilityLabel(t("menubarQuit"))
                .keyboardShortcut("q")
        }
        .font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 8) {
                summaryItem(t("lastSync"), value: model.lastSyncDate.map(model.shortDate) ?? t("never"), symbol: "clock")
                summaryItem(t("nextSync"), value: model.nextRunValue, symbol: "calendar")
            }
            primaryAction
            notice
            folders
            if let release = model.availableRelease {
                Button(String(format: t("menubarUpdate"), release.version)) { showWindow("settings") }
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            footer
        }
        .padding(16).frame(width: 356)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, model.config.language == "system" ? .current : Locale(identifier: model.config.language))
    }
}


struct ContentView: View {
    @ObservedObject var model: SyncModel
    @Environment(\.openWindow) private var openWindow

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
        .background {
            // Separate anchors so the preview and diff sheets never replace each other.
            Color.clear.sheet(item: $model.preview) { preview in
                SyncPreviewSheet(model: model, preview: preview)
            }
            Color.clear.sheet(item: $model.diffResult) { result in
                LatexDiffSheet(result: result, language: model.config.language)
            }
        }
        .onAppear {
            let action = openWindow
            URLCommandRouter.openMainWindow = {
                NSApp.setActivationPolicy(.regular)
                action(id: "main")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshState()
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
                if model.isSyncActive {
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
                rulesFileLocation
                LabeledContent(t("sharedRuleCount"), value: String(pair.excludePatterns.count))
            } header: {
                Text(t("oneDriveRulesTitle"))
            } footer: {
                Text(t("oneDriveOnlyHint"))
            }

            CloudOnlySection(model: model, pair: pair)
                .id(pair.id)

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
                        Stepper(value: $model.config.intervalHours, in: SyncConfig.intervalHourRange) {
                            LabeledContent(t("intervalHours"), value: "\(model.config.intervalHours) \(t("hours"))")
                        }
                    }
                }
                .disabled(!model.config.enabled)
            } header: {
                Text(t("schedule"))
            } footer: {
                Text(t("backgroundHint") + " "
                     + (model.config.scheduleMode == "daily" ? t("dailyHint") : String(
                         format: t("intervalRangeHint"), SyncConfig.intervalHourRange.lowerBound,
                         SyncConfig.intervalHourRange.upperBound)))
            }

            Section {
                Toggle(t("checkCloud"), isOn: $model.config.checkCloudBeforeSync)
            } footer: {
                Text(t("checkCloudHint"))
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
            oneDriveRulesSection
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


    private var rulesFileLocation: some View {
        LabeledContent(t("rulesFile")) {
            Text(OneDriveRules.filename)
                .foregroundStyle(.secondary).textSelection(.enabled)
            Button(t("revealRulesFile")) {
                if let url = OneDriveRules.configurationURL(model.config) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(OneDriveRules.configurationURL(model.config) == nil)
        }
    }

    private var oneDriveRulesSection: some View {
        Section {
            LabeledContent(t("oneDriveRoot")) {
                Text(model.config.oneDriveRoot.isEmpty ? "—" : abbreviatedPath(model.config.oneDriveRoot))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(model.config.oneDriveRoot)
                Button(t("chooseOneDriveRoot")) { model.chooseOneDriveRoot() }
            }
            rulesFileLocation
        } header: {
            Text(t("oneDriveRulesTitle"))
        } footer: {
            Text(t("oneDriveRootHint"))
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

}

private struct CloudOnlyReleaseTarget: Identifiable {
    let path: String
    var id: String { path }
}

private struct CloudOnlyReleaseRecovery: Identifiable {
    let id: String
    let relative: String
    let target: String
    let directory: URL
}

private struct CloudOnlyReleasePointer: Decodable {
    let status: String
    let journal: String
    let target: String
    let relative: String
}

/// Reads recovery pointers and checks only staging metadata. It never reads the
/// payload's contents, restores files, or removes a pointer or staging folder.
private func cloudOnlyReleaseRecoveries(at index: URL) -> (items: [CloudOnlyReleaseRecovery], unreadable: Bool) {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: index.path, isDirectory: &isDirectory) else { return ([], false) }
    guard isDirectory.boolValue,
          let pointers = try? manager.contentsOfDirectory(at: index,
              includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
        return ([], true)
    }
    var items: [CloudOnlyReleaseRecovery] = []
    var unreadable = false
    for url in pointers.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              metadata.isRegularFile == true, metadata.isSymbolicLink != true,
              let size = metadata.fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let pointer = try? JSONDecoder().decode(CloudOnlyReleasePointer.self, from: data) else {
            unreadable = true
            continue
        }
        if pointer.status == "released" || pointer.status == "rolled_back" { continue }
        guard pointer.journal.hasPrefix("/"), !pointer.journal.contains("\0"),
              pointer.target.hasPrefix("/"), !pointer.target.contains("\0"),
              let relative = try? normalizeCloudOnlyPath(pointer.relative) else {
            unreadable = true
            continue
        }
        let journal = URL(fileURLWithPath: pointer.journal).standardizedFileURL
        let directory = journal.deletingLastPathComponent()
        guard journal.lastPathComponent == "release.json",
              directory.lastPathComponent.hasPrefix(".pathsync-local-release-") else {
            unreadable = true
            continue
        }
        let payload = directory.appendingPathComponent("payload")
        if manager.fileExists(atPath: payload.path) {
            items.append(CloudOnlyReleaseRecovery(id: url.path, relative: relative,
                                                  target: pointer.target, directory: directory))
        }
    }
    return (items, unreadable)
}

private final class CloudOnlySectionState: ObservableObject {
    @Published var newPath = ""
    @Published var releaseTarget: CloudOnlyReleaseTarget?
    @Published var showsReleaseStatus = false
    @Published var recoveries: [CloudOnlyReleaseRecovery] = []
    @Published var recoveryReadFailed = false
    @Published var refreshingRecovery = false

    func refreshRecoveries(at index: URL) {
        guard !refreshingRecovery else { return }
        refreshingRecovery = true
        DispatchQueue.global(qos: .utility).async {
            let result = cloudOnlyReleaseRecoveries(at: index)
            DispatchQueue.main.async {
                self.recoveries = result.items
                self.recoveryReadFailed = result.unreadable
                self.refreshingRecovery = false
            }
        }
    }
}

/// A local storage choice, kept separate from the shared exclusion policy.
private struct CloudOnlySection: View {
    @ObservedObject var model: SyncModel
    let pair: SyncPair
    @StateObject private var state = CloudOnlySectionState()

    private func t(_ key: String) -> String { model.t(key) }

    private var recoveryIndex: URL {
        URL(fileURLWithPath: mergeStatePath(pair) + ".cloud-only-releases", isDirectory: true)
    }

    private func refreshRecoveries() {
        guard !model.isSyncActive else { return }
        state.refreshRecoveries(at: recoveryIndex)
    }

    private var canRelease: Bool {
        !model.hasUnsavedChanges && !model.isSyncActive
            && !pair.localPath.isEmpty && !pair.cloudPath.isEmpty
    }

    private var releaseHint: String {
        if model.isSyncActive { return t("cloudOnlyBusyHint") }
        if model.hasUnsavedChanges { return t("cloudOnlySaveFirst") }
        if pair.localPath.isEmpty || pair.cloudPath.isEmpty { return t("chooseFoldersHint") }
        return t("cloudOnlyReleaseHint")
    }

    private func addPath() {
        guard !model.isSyncActive, !state.newPath.isEmpty else { return }
        state.showsReleaseStatus = false
        model.addCloudOnlyPath(state.newPath, pairID: pair.id)
        if model.statusKey == "cloudOnlyAdded" { state.newPath = "" }
    }

    var body: some View {
        Section {
            Text(t("cloudOnlyHint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(t("cloudOnlyPathLabel"), text: $state.newPath,
                          prompt: Text(t("cloudOnlyPathPlaceholder")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPath)
                    .help(t("cloudOnlyPathHint"))
                    .accessibilityLabel(t("cloudOnlyPathLabel"))
                Button(t("cloudOnlyAdd"), action: addPath)
                    .disabled(state.newPath.isEmpty)
            }
            .disabled(model.isSyncActive)
            Text(t("cloudOnlyPathHint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if pair.cloudOnlyPaths.isEmpty {
                Text(t("cloudOnlyEmpty"))
                    .foregroundStyle(.secondary)
            } else if pair.cloudOnlyPaths.count > 3 {
                ScrollView {
                    pathRows
                }
                .frame(height: 250)
            } else {
                pathRows
            }

            if !state.recoveries.isEmpty || state.recoveryReadFailed {
                recoveryNotice
            }

            if state.showsReleaseStatus,
               ["releasingWorkingCopy", "workingCopyReleased", "error"].contains(model.statusKey) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(t(model.statusKey), systemImage: model.statusKey == "error"
                          ? "exclamationmark.triangle" : (model.statusKey == "releasingWorkingCopy"
                          ? "arrow.triangle.2.circlepath" : "checkmark.circle"))
                    if let detail = model.statusDetail, !detail.isEmpty {
                        ScrollView {
                            Text(detail)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(height: min(160, CGFloat(detail.components(separatedBy: "\n").count + 1) * 17))
                    }
                }
                .foregroundStyle(model.statusKey == "error" ? Color.red : Color.secondary)
            }
        } header: {
            HStack {
                Text(t("cloudOnlyTitle"))
                Spacer()
                if state.refreshingRecovery { ProgressView().controlSize(.small) }
                Button(action: refreshRecoveries) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(t("cloudOnlyRecoveryRefresh"))
                .accessibilityLabel(t("cloudOnlyRecoveryRefresh"))
                .disabled(model.isSyncActive || state.refreshingRecovery)
            }
        } footer: {
            Text(t("cloudOnlyRestoreHint"))
        }
        .sheet(item: $state.releaseTarget) { target in
            releaseConfirmation(target.path)
        }
        .onAppear(perform: refreshRecoveries)
        .onChange(of: model.isSyncActive) { active in
            if !active { refreshRecoveries() }
        }
        .onChange(of: model.statusKey) { key in
            if !["releasingWorkingCopy", "workingCopyReleased", "error"].contains(key) {
                state.showsReleaseStatus = false
            }
        }
    }

    private var recoveryNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.recoveries.isEmpty {
                Label(t("cloudOnlyRecoveryTitle"), systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text(t("cloudOnlyRecoveryHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.recoveries) { recovery in
                            HStack {
                                Text(recovery.relative)
                                    .font(.caption.monospaced())
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(recovery.target)
                                Spacer(minLength: 8)
                                Button(t("cloudOnlyRecoveryOpen")) {
                                    NSWorkspace.shared.open(recovery.directory)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(130, CGFloat(state.recoveries.count) * 37))
            }
            if state.recoveryReadFailed {
                Text(t("cloudOnlyRecoveryReadError"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(t("cloudOnlyRecoveryOpenRecords")) {
                    NSWorkspace.shared.open(recoveryIndex)
                }
                .controlSize(.small)
            }
        }
    }

    private var pathRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(pair.cloudOnlyPaths, id: \.self) { path in
                VStack(alignment: .leading, spacing: 7) {
                    Label {
                        Text(path)
                            .font(.body.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "icloud")
                            .foregroundStyle(.secondary)
                    }
                    .help(path)
                    HStack(spacing: 10) {
                        Button(t("cloudOnlyRelease")) {
                            state.releaseTarget = CloudOnlyReleaseTarget(path: path)
                        }
                        .disabled(!canRelease)
                        .help(releaseHint)
                        Button(t("cloudOnlyRestore")) {
                            state.showsReleaseStatus = false
                            model.removeCloudOnlyPath(path, pairID: pair.id)
                        }
                        .disabled(model.isSyncActive)
                        .help(t("cloudOnlyRestoreHint"))
                        Spacer(minLength: 0)
                        Button {
                            model.openCloudOnlyTarget(path, pairID: pair.id)
                        } label: {
                            Label(t("cloudOnlyOpenTarget"), systemImage: "folder")
                        }
                        .disabled(pair.cloudPath.isEmpty)
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if path != pair.cloudOnlyPaths.last { Divider() }
            }
        }
        .padding(.vertical, 3)
    }

    private func releaseConfirmation(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("cloudOnlyConfirmTitle"), systemImage: "externaldrive.badge.exclamationmark")
                .font(.title3.weight(.semibold))
            Text(path)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .help(path)
            Text(t("cloudOnlyConfirmScope"))
            Text(t("cloudOnlyConfirmVerification"))
            Text(t("cloudOnlyConfirmCache"))
                .foregroundStyle(.secondary)
            Button {
                model.openCloudOnlyTarget(path, pairID: pair.id)
            } label: {
                Label(t("cloudOnlyOpenTarget"), systemImage: "folder")
            }
            .disabled(pair.cloudPath.isEmpty)
            Divider()
            HStack {
                Spacer()
                Button(t("cancel")) { state.releaseTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button(t("cloudOnlyConfirmRelease"), role: .destructive) {
                    state.releaseTarget = nil
                    state.showsReleaseStatus = true
                    model.releaseCloudOnlyPath(path, pairID: pair.id)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canRelease)
            }
        }
        .font(.callout)
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
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
