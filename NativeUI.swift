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

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .lineLimit(1)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: SyncModel
    @Environment(\.openWindow) private var openWindow

    private func t(_ key: String) -> String { uiText(key, language: model.config.language) }

    private func showWindow(_ page: String) {
        model.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        if model.busy {
            Text(t("syncingAll"))
        } else if model.conflictCount > 0 {
            Text(String(format: t("menubarPending"), model.conflictCount))
        } else if !model.hasEnabledPairs {
            Text(t("menubarNoPairs"))
        } else {
            Text(t("ready"))
        }

        Divider()
        Button {
            model.syncNow(all: true)
        } label: {
            Label(t("syncAllNow"), systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(model.busy || !model.hasEnabledPairs)

        Button(t("menubarOpen")) { showWindow("overview") }
        Button(t("menubarOpenHistory")) { showWindow("history") }

        Divider()
        if let release = model.availableRelease {
            Button(String(format: t("menubarUpdate"), release.version)) { showWindow("about") }
        } else {
            Button(t("checkForUpdates")) {
                model.checkForUpdates()
                showWindow("about")
            }
        }
        Button(t("menubarQuit")) { NSApp.terminate(nil) }
    }
}

struct ContentView: View {
    @ObservedObject var model: SyncModel
    @State private var confirmingRemoval = false

    private func t(_ key: String) -> String { uiText(key, language: model.config.language) }

    private var locale: Locale { Locale(identifier: usesEnglish(model.config.language) ? "en" : "zh-Hans") }

    private var selectedRoute: Binding<String?> {
        Binding(get: {
            if model.page == "pair", let id = model.selectedID { return "pair:\(id.uuidString)" }
            return model.page
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

    private func displayName(_ pair: SyncPair) -> String {
        pair.name.isEmpty ? t("unnamed") : pair.name
    }

    private var pageTitle: String {
        switch model.page {
        case "about": return t("about")
        case "history": return t("history")
        case "settings": return t("settings")
        case "pair": return model.selectedPair.map { displayName($0) } ?? t("folders")
        default: return t("overview")
        }
    }

    private var scheduleSummary: String {
        if model.config.scheduleMode == "daily" {
            return "\(t("scheduleSummaryDaily")) \(String(format: "%02d:%02d", model.config.dailyHour, model.config.dailyMinute))"
        }
        return "\(t("scheduleSummaryInterval")) \(model.config.intervalHours) \(t("hours"))"
    }

    private func relativeText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var nextRunText: String {
        guard model.config.enabled else { return t("scheduleOff") }
        guard model.config.scheduleMode == "daily" else { return scheduleSummary }
        var parts = DateComponents()
        parts.hour = model.config.dailyHour
        parts.minute = model.config.dailyMinute
        guard let next = Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime) else {
            return scheduleSummary
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "\(t("nextRun")) \(formatter.string(from: next))"
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
        .frame(minWidth: 820, minHeight: 560)
        .environment(\.locale, model.config.language == "system" ? .current : Locale(identifier: model.config.language))
        .confirmationDialog(String(format: t("removeConfirm"), model.selectedPair.map { displayName($0) } ?? ""),
                            isPresented: $confirmingRemoval) {
            Button(t("removeFolder"), role: .destructive) { model.removeSelected() }
        } message: {
            Text(t("removeConfirmHint"))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshConflicts()
            model.refreshHistory()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            model.refreshConflicts()
            model.refreshHistory()
            model.checkForUpdates(automatic: true)
        }
    }

    private var sidebar: some View {
        List(selection: selectedRoute) {
            Label(t("overview"), systemImage: "square.grid.2x2")
                .badge(model.conflictCount)
                .tag("overview")
            Section(t("folders")) {
                ForEach(model.config.pairs) { pair in
                    Label {
                        Text(displayName(pair))
                            .foregroundStyle(pair.enabled ? Color.primary : Color.secondary)
                    } icon: {
                        Image(systemName: directionIcon(pair.scheduledDirection))
                            .foregroundStyle(pair.enabled ? Color.accentColor : .secondary)
                    }
                    .badge(model.conflictsByPair[pair.id]?.count ?? 0)
                    .tag("pair:\(pair.id.uuidString)")
                    .contextMenu {
                        Button(t("removeFolder") + "…") {
                            openPair(pair)
                            confirmingRemoval = true
                        }
                    }
                }
            }
            Section {
                Label(t("history"), systemImage: "clock.arrow.circlepath")
                    .tag("history")
                Label(t("settings"), systemImage: "gearshape")
                    .tag("settings")
                Label(t("about"), systemImage: "info.circle")
                    .badge(model.availableRelease == nil ? nil : Text(t("updateBadge")))
                    .tag("about")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.addPair() } label: {
                    Label(t("addFolder"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.page == "pair", let pair = model.selectedPair {
                Button { model.syncNow() } label: {
                    Label(t("syncPairNow"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(t("syncPairHint"))
                .disabled(model.busy || pair.localPath.isEmpty || pair.cloudPath.isEmpty)
            } else {
                Button { model.syncNow(all: true) } label: {
                    Label(t("syncAllNow"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(t("syncAllHint"))
                .disabled(model.busy || !model.hasEnabledPairs)
            }
        }
        ToolbarItem(placement: .primaryAction) {
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
        case "settings":
            settingsForm
        case "history":
            HistoryPage(records: model.history, pairs: model.config.pairs,
                        language: model.config.language, error: model.historyError,
                        refresh: model.refreshHistory,
                        restore: { pair, id in model.restoreBackup(pair: pair, id: id) })
        case "about":
            aboutForm
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
                statusCard
                if let release = model.availableRelease { updateBanner(release) }
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("folders")).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(model.config.pairs) { pair in pairCard(pair) }
                        addPairCard
                    }
                }
                scheduleCard
            }
            .padding(24)
        }
    }

    private var statusHeadline: String {
        if model.busy { return t("syncing") }
        if model.conflictCount > 0 { return String(format: t("menubarPending"), model.conflictCount) }
        if !model.hasEnabledPairs { return t("menubarNoPairs") }
        return t("statusReady")
    }

    private var overviewSubtitle: String {
        let last = model.lastSyncDate.map { relativeText($0) } ?? t("never")
        return "\(t("lastSync")) \(last) · \(nextRunText)"
    }

    private var statusCard: some View {
        Card {
            HStack(spacing: 16) {
                Group {
                    if model.busy {
                        ProgressView()
                    } else if model.conflictCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if !model.hasEnabledPairs {
                        Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .font(.system(size: 34))
                .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusHeadline).font(.title2.weight(.semibold))
                    Text(overviewSubtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { model.syncNow(all: true) } label: {
                    Label(t("syncAllNow"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || !model.hasEnabledPairs)
            }
        }
    }

    private func updateBanner(_ release: AppRelease) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: t("updateAvailable"), release.version)).font(.headline)
                    Text(t("updateInstallHint")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(t("updateDetails")) { model.page = "about" }
                Button(t("updateDownload")) { NSWorkspace.shared.open(release.downloadURL ?? release.pageURL) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func pairStatus(_ pair: SyncPair) -> (String, Color) {
        if !pair.enabled { return (t("disabled"), .secondary) }
        if pair.localPath.isEmpty || pair.cloudPath.isEmpty { return (t("pairNotConfigured"), .secondary) }
        if let count = model.conflictsByPair[pair.id]?.count, count > 0 {
            return (String(format: t("pairPending"), count), .orange)
        }
        if let record = model.lastRecord(for: pair), record.hasFailures || record.finishedAt == nil {
            return (t("pairLastFailed"), .red)
        }
        return (t("pairOK"), .green)
    }

    private func pairFootnote(_ pair: SyncPair) -> String {
        let direction = t(pair.scheduledDirection)
        guard let record = model.lastRecord(for: pair) else { return "\(direction) · \(t("lastSync")) \(t("never"))" }
        return "\(direction) · \(t("lastSync")) \(relativeText(record.finishedAt ?? record.startedAt))"
    }

    private func pathLine(_ icon: String, _ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 16)
            Text(path.isEmpty ? t("folderNotChosen") : abbreviatedPath(path))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func pairCard(_ pair: SyncPair) -> some View {
        let status = pairStatus(pair)
        return Button { openPair(pair) } label: {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: directionIcon(pair.scheduledDirection))
                            .foregroundStyle(pair.enabled ? Color.accentColor : .secondary)
                        Text(displayName(pair)).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        StatusBadge(text: status.0, color: status.1)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        pathLine("laptopcomputer", pair.localPath)
                        pathLine("cloud", pair.cloudPath)
                    }
                    Text(pairFootnote(pair)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addPairCard: some View {
        Button { model.addPair() } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.title2)
                Text(t("addFolder"))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scheduleCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "calendar")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("schedule")).font(.headline)
                    Text("\(scheduleSummary) · \(t(model.config.enabled ? "backgroundOn" : "scheduleOff"))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("editSchedule")) { model.page = "settings" }
            }
        }
    }

    // MARK: - Folder pair

    private func pairPage(_ index: Int) -> some View {
        let pair = model.config.pairs[index]
        return Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(pair.enabled ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(t("namePlaceholder"), text: $model.config.pairs[index].name)
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                        Text(pairFootnote(pair)).font(.callout).foregroundStyle(.secondary)
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
                    Button(scheduleSummary) { model.page = "settings" }
                        .buttonStyle(.link)
                }
                LabeledContent(t("runNow")) {
                    HStack(spacing: 8) {
                        Menu(t("syncOnceIn")) {
                            Button(t("merge")) { model.syncNow(.merge) }
                            Button(t("upload")) { model.syncNow(.upload) }
                            Button(t("download")) { model.syncNow(.download) }
                        }
                        .fixedSize()
                        Button { model.syncNow() } label: {
                            Label(t("syncNow"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(model.busy || pair.localPath.isEmpty || pair.cloudPath.isEmpty)
                }
            } header: {
                Text(t("directionSection"))
            } footer: {
                Text(t(model.config.conflictPolicy == "keep-both" ? "directionHintAuto" :
                       (model.config.conflictPolicy == "newest" ? "directionHintNewest" : "directionHintAsk")))
            }

            conflictsSection(index)

            Section {
                Button(role: .destructive) { confirmingRemoval = true } label: {
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

    private func conflictsSection(_ index: Int) -> some View {
        Section {
            if model.selectedConflicts.isEmpty {
                Label(t("noConflicts"), systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.selectedConflicts) { conflict in
                    conflictRow(conflict, index: index)
                }
            }
        } header: {
            HStack {
                Text(t("conflicts"))
                if !model.selectedConflicts.isEmpty {
                    StatusBadge(text: "\(model.selectedConflicts.count)", color: .orange)
                }
                Spacer()
                Button { model.refreshConflicts() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(t("refreshConflicts"))
            }
        } footer: {
            if !model.selectedConflicts.isEmpty { Text(t("conflictHint")) }
        }
    }

    private func conflictRow(_ conflict: PendingConflict, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(conflict.name).font(.body).textSelection(.enabled)
            } icon: {
                Image(systemName: conflict.isTree ? "folder.badge.questionmark" : "doc.on.doc")
                    .foregroundStyle(.orange)
            }
            if conflict.isTree {
                Text(t("directoryConflict"))
                    .foregroundStyle(.orange)
                    .font(.caption)
                HStack {
                    Button(t("viewLocal")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.config.pairs[index].localPath))
                    }
                    Button(t("viewCloud")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.config.pairs[index].cloudPath))
                    }
                }
                .controlSize(.small)
            } else if let sidecar = conflict.sidecar {
                Text(t("reviewOutstanding"))
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("\(t("reviewCopy")) \(sidecar)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if conflict.blockedByTree != nil {
                    Text(t("childBlockedByTree"))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(t("viewMainFile")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: model.config.pairs[index].localPath)
                                .appendingPathComponent(conflict.name)
                        ])
                    }
                    Button(t("viewReviewCopy")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: model.config.pairs[index].localPath)
                                .appendingPathComponent(sidecar)
                        ])
                    }
                    Spacer()
                    Button(t("chooseNewest")) { model.chooseNewestForReview(conflict.name) }
                        .disabled(model.busy || conflict.blockedByTree != nil)
                    Button(t("confirmReviewed")) { model.acknowledgeConflict(conflict.name) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || conflict.blockedByTree != nil)
                }
                .controlSize(.small)
            } else {
                Text(conflict.localMissing || conflict.cloudMissing
                     ? t("deleteEditConflict")
                     : "\(t("local")) \(ByteCountFormatter.string(fromByteCount: conflict.localBytes, countStyle: .file)) · \(t("cloud")) \(ByteCountFormatter.string(fromByteCount: conflict.cloudBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                if conflict.blockedByTree != nil {
                    Text(t("childBlockedByTree"))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(t("viewLocal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: model.config.pairs[index].localPath)
                                .appendingPathComponent(conflict.name)
                        ])
                    }
                    Button(t("viewCloud")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: model.config.pairs[index].cloudPath)
                                .appendingPathComponent(conflict.name)
                        ])
                    }
                    Spacer()
                    Menu(t("resolve")) {
                        Button(conflict.localMissing ? t("keepDeletion") : t("useLocal")) {
                            model.resolveConflict(conflict.name, choice: "local")
                        }
                        Button(conflict.cloudMissing ? t("keepDeletion") : t("useCloud")) {
                            model.resolveConflict(conflict.name, choice: "cloud")
                        }
                        if !conflict.localMissing && !conflict.cloudMissing {
                            Button(t("chooseNewest")) {
                                model.resolveConflict(conflict.name, choice: "newest")
                            }
                            Button(t("keepBoth")) { model.resolveConflict(conflict.name, choice: "both") }
                        }
                    }
                    .fixedSize()
                    .disabled(model.busy || conflict.blockedByTree != nil)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
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
            } header: {
                Text(t("notifications"))
            } footer: {
                Text(t("notificationHint"))
            }

            Section {
                Picker(t("language"), selection: $model.config.language) {
                    Text(t("systemLanguage")).tag("system")
                    Text(t("chinese")).tag("zh-Hans")
                    Text(t("english")).tag("en")
                }
                .pickerStyle(.menu)
                Toggle(t("autoCheckUpdates"), isOn: $model.config.checkForUpdates)
            } header: {
                Text(t("general"))
            } footer: {
                Text(t("autoCheckHint"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About and updates

    private var updateStatusText: String {
        switch model.update {
        case .idle: return t("updateNotChecked")
        case .checking: return t("updateChecking")
        case .upToDate: return t("updateUpToDate")
        case .failed: return t("updateFailed")
        case .available(let release): return String(format: t("updateAvailable"), release.version)
        }
    }

    @ViewBuilder
    private var updateStatusIcon: some View {
        switch model.update {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .available: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .idle: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var lastCheckedText: String {
        "\(t("updateLastChecked")) \(model.lastUpdateCheck.map { relativeText($0) } ?? t("never"))"
    }

    private var aboutForm: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t("appName")).font(.title2.weight(.semibold))
                        Text("\(t("version")) \(model.currentVersion)").foregroundStyle(.secondary)
                        Text(t("aboutSubtitle")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

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
                        Button(t("updateReleaseNotes")) { NSWorkspace.shared.open(release.pageURL) }
                        Button(t("updateDownload")) {
                            NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
                        }
                        .buttonStyle(.borderedProminent)
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
                    Text(t("updateInstallHint")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("autoCheckUpdates"), isOn: $model.config.checkForUpdates)
            } header: {
                Text(t("updates"))
            } footer: {
                Text(t("autoCheckHint"))
            }

            Section {
                LabeledContent(t("source")) {
                    Link("github.com/ensomnia16/PathSync", destination: URL(string: "https://github.com/ensomnia16/PathSync")!)
                }
                LabeledContent(t("author")) {
                    Link("ensomnia16", destination: URL(string: "https://github.com/ensomnia16")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}
