import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = SyncModel()

    private func t(_ key: String) -> String { uiText(key, language: model.config.language) }

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

    private var pageTitle: String {
        switch model.page {
        case "about": return t("about")
        case "pair": return model.selectedPair?.name.isEmpty == false ? model.selectedPair!.name : t("unnamed")
        default: return t("schedule")
        }
    }

    private var scheduleSummary: String {
        if model.config.scheduleMode == "daily" {
            return "\(t("scheduleSummaryDaily")) \(String(format: "%02d:%02d", model.config.dailyHour, model.config.dailyMinute))"
        }
        return "\(t("scheduleSummaryInterval")) \(model.config.intervalHours) \(t("hours"))"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selectedRoute) {
                Section {
                    HStack {
                        Label(t("schedule"), systemImage: "calendar")
                        Spacer()
                        if model.conflictCount > 0 {
                            Text("\(model.conflictCount)")
                                .foregroundStyle(.orange)
                        }
                    }.tag("schedule")
                }
                Section(t("folders")) {
                    ForEach(model.config.pairs) { pair in
                        HStack {
                            Label(pair.name.isEmpty ? t("unnamed") : pair.name,
                                  systemImage: pair.enabled ? "folder" : "folder.badge.questionmark")
                            Spacer()
                            if let count = model.conflictsByPair[pair.id]?.count, count > 0 {
                                Text("\(count)")
                                    .foregroundStyle(.orange)
                            }
                        }.tag("pair:\(pair.id.uuidString)")
                    }
                }
                Section {
                    Label(t("about"), systemImage: "info.circle")
                        .tag("about")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 290)
        } detail: {
            detail
                .navigationTitle(pageTitle)
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        Button { model.addPair() } label: {
                            Label(t("addFolder"), systemImage: "plus")
                        }
                        .help(t("addFolder"))
                        .keyboardShortcut("n", modifiers: .command)
                        if model.page == "pair", model.selectedID != nil {
                            Button { model.removeSelected() } label: {
                                Label(t("removeFolder"), systemImage: "minus")
                            }
                            .help(t("removeFolder"))
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) } label: {
                            Label(t("log"), systemImage: "doc.text")
                        }
                        .help(t("log"))
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(t("save")) { model.save() }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(model.busy)
                    }
                }
        }
        .frame(minWidth: 780, minHeight: 520)
        .environment(\.locale, model.config.language == "system" ? .current : Locale(identifier: model.config.language))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshConflicts()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            model.refreshConflicts()
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if model.page == "schedule" { scheduleForm }
            else if model.page == "about" { aboutForm }
            else if let index = model.selectedIndex { pairForm(index) }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.largeTitle)
                    Text(t("empty"))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                else if model.conflictCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                Text(model.statusDetail ?? t(model.statusKey))
                    .lineLimit(2)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
    }

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

    private var scheduleForm: some View {
        Form {
            Section {
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
            } header: {
                Text(t("schedule"))
            } footer: {
                Text(model.config.scheduleMode == "daily" ? t("dailyHint") : t("atLeastSix"))
            }

            Section {
                Toggle(t("background"), isOn: $model.config.enabled)
                Toggle(t("latex"), isOn: $model.config.excludeLatexIntermediates)
            } footer: {
                Text(t("backgroundHint") + " " + t("filterHint"))
            }

            Section {
                Button(t("runAll")) { model.syncNow(all: true) }
                    .disabled(model.busy || !model.config.pairs.contains(where: { $0.enabled }))
            }
        }
        .formStyle(.grouped)
    }

    private func pathField(_ title: String, path: Binding<String>, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 62, alignment: .leading)
            HStack(spacing: 8) {
                TextField(t("chooseFolder"), text: path)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .accessibilityLabel(title)
                Button(t("browse"), action: choose)
            }
        }
    }

    private func pairForm(_ index: Int) -> some View {
        Form {
            Section {
                Toggle(t("pairEnabled"), isOn: $model.config.pairs[index].enabled)
                HStack(spacing: 8) {
                    Text(t("name")).frame(width: 62, alignment: .leading)
                    TextField(t("namePlaceholder"), text: $model.config.pairs[index].name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                }
                pathField(t("local"), path: $model.config.pairs[index].localPath) {
                    model.chooseFolder(local: true)
                }
                pathField(t("cloud"), path: $model.config.pairs[index].cloudPath) {
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
                .pickerStyle(.menu)
                LabeledContent(t("usingSchedule")) {
                    Button(scheduleSummary) { model.page = "schedule" }
                        .buttonStyle(.link)
                }
            } footer: {
                Text(t("directionHint"))
            }

            Section(t("runNow")) {
                HStack(spacing: 8) {
                    Button(t("merge")) { model.syncNow(.merge) }
                    Button(t("upload")) { model.syncNow(.upload) }
                    Button(t("download")) { model.syncNow(.download) }
                }
                .disabled(model.busy)
            }

            Section {
                if model.selectedConflicts.isEmpty {
                    Text(t("noConflicts")).foregroundStyle(.secondary)
                } else {
                    ForEach(model.selectedConflicts) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(conflict.name).font(.body).textSelection(.enabled)
                            Text("\(t("local")) \(ByteCountFormatter.string(fromByteCount: conflict.localBytes, countStyle: .file)) · \(t("cloud")) \(ByteCountFormatter.string(fromByteCount: conflict.cloudBytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
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
                                    Button(t("useLocal")) { model.resolveConflict(conflict.name, choice: "local") }
                                    Button(t("useCloud")) { model.resolveConflict(conflict.name, choice: "cloud") }
                                    Button(t("keepBoth")) { model.resolveConflict(conflict.name, choice: "both") }
                                }
                                .disabled(model.busy)
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                HStack {
                    Text(t("conflicts"))
                    Spacer()
                    Button { model.refreshConflicts() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(t("refreshConflicts"))
                }
            } footer: {
                Text(t("conflictHint"))
            }
        }
        .formStyle(.grouped)
    }

    private var aboutForm: some View {
        Form {
            Section {
                Picker(t("language"), selection: $model.config.language) {
                    Text(t("systemLanguage")).tag("system")
                    Text(t("chinese")).tag("zh-Hans")
                    Text(t("english")).tag("en")
                }
                .pickerStyle(.menu)
            }
            Section {
                LabeledContent(t("version"), value: "2.5.1")
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
