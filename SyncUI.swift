import AppKit
import SwiftUI

private let translations: [String: (zh: String, en: String)] = [
    "appName": ("路径同步", "PathSync"),
    "schedule": ("默认计划", "Default schedule"),
    "scheduleSubtitle": ("所有已启用路径共用这项计划；每组可单独选择同步方向。", "All enabled folders follow this schedule. Each folder has its own sync direction."),
    "folders": ("同步路径", "Folders"),
    "addFolder": ("添加路径", "Add folder"),
    "removeFolder": ("移除路径", "Remove folder"),
    "about": ("关于", "About"),
    "unnamed": ("未命名路径", "Unnamed folder"),
    "disabled": ("未启用", "Disabled"),
    "log": ("打开日志", "Open log"),
    "save": ("保存设置", "Save settings"),
    "ready": ("准备就绪", "Ready"),
    "chooseFoldersHint": ("选择本地和云端文件夹，然后保存。", "Choose local and cloud folders, then save."),
    "removedHint": ("已从列表移除；保存后生效。", "Removed from the list. Save to apply."),
    "savedEnabled": ("已保存，后台同步已启用。", "Saved. Scheduled sync is on."),
    "savedDisabled": ("已保存，后台同步已关闭。", "Saved. Scheduled sync is off."),
    "syncingAll": ("正在同步所有已启用路径…", "Syncing all enabled folders…"),
    "syncingPair": ("正在同步所选路径…", "Syncing the selected folder…"),
    "doneAll": ("所有已启用路径同步完成。", "All enabled folders are synced."),
    "donePair": ("所选路径同步完成。", "Selected folder is synced."),
    "error": ("操作失败", "Operation failed"),
    "daily": ("每天固定时间", "Every day at a time"),
    "interval": ("固定间隔", "At an interval"),
    "runMode": ("运行方式", "Run mode"),
    "runTime": ("同步时间", "Sync time"),
    "intervalHours": ("间隔", "Interval"),
    "hours": ("小时", "hours"),
    "atLeastSix": ("可设为 6 至 168 小时。间隔从任务安装后开始计算。", "Set 6–168 hours. The interval starts when the scheduled task is installed."),
    "dailyHint": ("按这台 Mac 的本地时间运行。", "Runs at this Mac’s local time."),
    "background": ("启用后台同步", "Enable scheduled sync"),
    "backgroundHint": ("设置保存在本机，由 macOS 在你登录期间定时运行。", "Settings stay on this Mac. macOS runs the task while you are signed in."),
    "filterTitle": ("文件过滤", "File filtering"),
    "latex": ("跳过 LaTeX 中间文件", "Skip LaTeX build files"),
    "filterHint": ("也会跳过虚拟环境与缓存。同步不会删除任一侧文件。", "Virtual environments and caches are also skipped. Sync never deletes files on either side."),
    "runAll": ("现在同步全部路径", "Sync all folders now"),
    "pairSubtitle": ("本地工作目录与已挂载的云端目录。", "A local working folder and a mounted cloud folder."),
    "pairEnabled": ("启用这组路径", "Enable this folder pair"),
    "name": ("名称", "Name"),
    "namePlaceholder": ("例如：论文项目", "For example: Paper project"),
    "local": ("本地", "Local"),
    "cloud": ("云端", "Cloud"),
    "chooseFolder": ("选择文件夹", "Choose folder"),
    "browse": ("选择…", "Choose…"),
    "direction": ("定时方向", "Scheduled direction"),
    "merge": ("双向合并", "Two-way merge"),
    "upload": ("本地 → 云端", "Local → cloud"),
    "download": ("云端 → 本地", "Cloud → local"),
    "directionHint": ("两侧同时修改同一文件时会报告冲突，并保留原件。", "Conflicting edits are reported and both originals are preserved."),
    "usingSchedule": ("使用默认计划", "Uses default schedule"),
    "editSchedule": ("编辑计划", "Edit schedule"),
    "runNow": ("立即执行", "Run now"),
    "empty": ("还没有路径。点击左侧的“添加路径”开始。", "No folders yet. Use Add folder in the sidebar."),
    "language": ("界面语言", "Interface language"),
    "systemLanguage": ("跟随系统", "Follow system"),
    "chinese": ("简体中文", "Simplified Chinese"),
    "english": ("English", "English"),
    "aboutSubtitle": ("简单、可检查的本地文件夹同步。", "Simple, inspectable local folder sync."),
    "version": ("版本", "Version"),
    "source": ("源代码与发布版本", "Source code and releases"),
    "author": ("作者", "Author"),
    "scheduleSummaryDaily": ("每天", "Every day at"),
    "scheduleSummaryInterval": ("每隔", "Every"),
    "manual": ("手动", "Manual"),
]

func usesEnglish(_ language: String) -> Bool {
    language == "en" || (language == "system" && !(Locale.preferredLanguages.first ?? "zh").hasPrefix("zh"))
}

func uiText(_ key: String, language: String) -> String {
    guard let value = translations[key] else { return key }
    return usesEnglish(language) ? value.en : value.zh
}

func uiError(_ error: Error, language: String) -> String {
    guard usesEnglish(language) else { return error.localizedDescription }
    let value = error as NSError
    guard value.domain == "com.ensom.ResearchSync" else { return "The operation failed. Open the log for details." }
    switch value.code {
    case 1: return "Choose both local and cloud folders for this pair."
    case 2: return "The local folder does not exist. Check its path."
    case 3: return "The cloud folder does not exist. Check its path."
    case 4: return "A folder pair cannot use the same directory or nested directories."
    case 6: return "Another sync is already running."
    case 7: return "There are no folders to sync."
    case 9: return "Enable at least one folder before turning on scheduled sync."
    default: return "The operation did not complete. Open the log for details."
    }
}

struct ContentView: View {
    @StateObject private var model = SyncModel()
    private let ink = Color(red: 0.17, green: 0.26, blue: 0.23)
    private let accent = Color(red: 0.70, green: 0.30, blue: 0.20)
    private let paper = Color(red: 0.975, green: 0.972, blue: 0.955)

    private func t(_ key: String) -> String { uiText(key, language: model.config.language) }

    private var scheduleSummary: String {
        if model.config.scheduleMode == "daily" {
            return "\(t("scheduleSummaryDaily")) \(String(format: "%02d:%02d", model.config.dailyHour, model.config.dailyMinute))"
        }
        return "\(t("scheduleSummaryInterval")) \(model.config.intervalHours) \(t("hours"))"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 228)
            Rectangle().fill(ink.opacity(0.12)).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 890, minHeight: 605)
        .background(paper)
        .tint(accent)
        .environment(\.locale, model.config.language == "system" ? .current : Locale(identifier: model.config.language))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t("appName")).font(.system(size: 16, weight: .semibold))
                    Text("2.3.0").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 17).padding(.top, 28).padding(.bottom, 27)

            sidebarButton("schedule", icon: "calendar", selected: model.page == "schedule") {
                model.page = "schedule"
            }
            Text(scheduleSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 46).padding(.top, 2).padding(.bottom, 19)

            HStack {
                Text(t("folders")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.config.pairs.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 19).padding(.bottom, 7)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.config.pairs) { pair in
                        Button {
                            model.selectedID = pair.id
                            model.page = "pair"
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "folder")
                                    .font(.system(size: 14)).frame(width: 19)
                                    .foregroundStyle(pair.enabled ? ink : .secondary)
                                Text(pair.name.isEmpty ? t("unnamed") : pair.name)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if !pair.enabled { Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                            }
                            .font(.system(size: 12, weight: model.selectedID == pair.id && model.page == "pair" ? .semibold : .regular))
                            .padding(.horizontal, 11).frame(height: 34)
                            .background(model.selectedID == pair.id && model.page == "pair" ? ink.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
            }

            Divider().padding(.horizontal, 16).padding(.vertical, 10)
            sidebarButton("addFolder", icon: "plus", selected: false) { model.addPair() }
            if model.page == "pair" && model.selectedID != nil {
                sidebarButton("removeFolder", icon: "minus", selected: false) { model.removeSelected() }
            }
            sidebarButton("about", icon: "info.circle", selected: model.page == "about") {
                model.page = "about"
            }
            .padding(.top, 8).padding(.bottom, 13)
        }
        .background(Color(red: 0.942, green: 0.942, blue: 0.918))
    }

    private func sidebarButton(_ key: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 19)
                Text(t(key)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 11).frame(height: 34)
            .background(selected ? ink.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if model.page == "schedule" { schedulePage }
                    else if model.page == "about" { aboutPage }
                    else if let index = model.selectedIndex { pairPage(index) }
                    else { Text(t("empty")).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: 690, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 35).padding(.top, 31).padding(.bottom, 30)
            }
            Divider()
            HStack(spacing: 9) {
                Circle().fill(model.busy ? accent : ink).frame(width: 6, height: 6)
                Text(model.statusDetail ?? t(model.statusKey))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(t("log")) { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ink)
                Button(t("save")) { model.save() }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 30).frame(height: 56)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.page == "schedule" ? t("schedule") : model.page == "about" ? t("about") :
                 (model.selectedPair?.name.isEmpty == false ? model.selectedPair!.name : t("unnamed")))
                .font(.system(size: 27, weight: .semibold, design: .default))
                .foregroundStyle(ink)
            Text(model.page == "schedule" ? t("scheduleSubtitle") :
                 model.page == "about" ? t("aboutSubtitle") : t("pairSubtitle"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 33)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
            .padding(.bottom, 11)
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

    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(t("runMode"))
            Picker(t("runMode"), selection: $model.config.scheduleMode) {
                Text(t("daily")).tag("daily")
                Text(t("interval")).tag("interval")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 350)
            .padding(.bottom, 27)

            if model.config.scheduleMode == "daily" {
                formLine(t("runTime")) {
                    DatePicker(t("runTime"), selection: dailyTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field).labelsHidden().frame(width: 115)
                }
                Text(t("dailyHint")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 122).padding(.top, 4)
            } else {
                formLine(t("intervalHours")) {
                    Stepper(value: $model.config.intervalHours, in: 6...168) {
                        Text("\(model.config.intervalHours) \(t("hours"))")
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .frame(width: 160)
                }
                Text(t("atLeastSix")).font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 122).padding(.top, 4)
            }

            Divider().padding(.vertical, 28)
            sectionTitle(t("background"))
            Toggle(t("background"), isOn: $model.config.enabled).labelsHidden()
            Text(t("backgroundHint")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)

            Divider().padding(.vertical, 28)
            sectionTitle(t("filterTitle"))
            Toggle(t("latex"), isOn: $model.config.excludeLatexIntermediates)
            Text(t("filterHint")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 7)

            Divider().padding(.vertical, 28)
            Button(t("runAll")) { model.syncNow(all: true) }
                .buttonStyle(.bordered).disabled(model.busy || !model.config.pairs.contains(where: { $0.enabled }))
        }
        .font(.system(size: 12))
    }

    private func formLine<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }

    private func pathLine(_ title: String, path: Binding<String>, choose: @escaping () -> Void) -> some View {
        formLine(title) {
            TextField(t("chooseFolder"), text: path)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel(title)
            Button(t("browse"), action: choose).controlSize(.small)
        }
    }

    private func pairPage(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(t("pairEnabled"), isOn: $model.config.pairs[index].enabled)
                .padding(.bottom, 24)
            formLine(t("name")) {
                TextField(t("namePlaceholder"), text: $model.config.pairs[index].name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.bottom, 10)
            pathLine(t("local"), path: $model.config.pairs[index].localPath) { model.chooseFolder(local: true) }
                .padding(.bottom, 10)
            pathLine(t("cloud"), path: $model.config.pairs[index].cloudPath) { model.chooseFolder(local: false) }

            Divider().padding(.vertical, 28)
            sectionTitle(t("direction"))
            Picker(t("direction"), selection: $model.config.pairs[index].scheduledDirection) {
                Text(t("merge")).tag("merge")
                Text(t("upload")).tag("upload")
                Text(t("download")).tag("download")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 455)
            Text(t("directionHint")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)

            Divider().padding(.vertical, 28)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("usingSchedule")).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                    Text(scheduleSummary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("editSchedule")) { model.page = "schedule" }
            }

            Divider().padding(.vertical, 28)
            sectionTitle(t("runNow"))
            HStack(spacing: 9) {
                Button(t("merge")) { model.syncNow(.merge) }.buttonStyle(.borderedProminent)
                Button(t("upload")) { model.syncNow(.upload) }.buttonStyle(.bordered)
                Button(t("download")) { model.syncNow(.download) }.buttonStyle(.bordered)
            }
            .disabled(model.busy)
        }
        .font(.system(size: 12))
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(t("language"))
            Picker(t("language"), selection: $model.config.language) {
                Text(t("systemLanguage")).tag("system")
                Text(t("chinese")).tag("zh-Hans")
                Text(t("english")).tag("en")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 390)
            Divider().padding(.vertical, 28)
            formLine(t("version")) { Text("2.3.0").font(.system(size: 12, design: .monospaced)) }
            formLine(t("source")) {
                Link("github.com/ensomnia16/PathSync", destination: URL(string: "https://github.com/ensomnia16/PathSync")!)
            }
            formLine(t("author")) {
                Link("ensomnia16", destination: URL(string: "https://github.com/ensomnia16")!)
            }
        }
    }
}
