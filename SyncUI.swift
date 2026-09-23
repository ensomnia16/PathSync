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
    "conflictsPending": ("有待处理冲突，请打开对应路径查看。", "Pending conflicts need review. Open the affected folder."),
    "chooseFoldersHint": ("选择本地和云端文件夹，然后保存。", "Choose local and cloud folders, then save."),
    "removedHint": ("已从列表移除；保存后生效。", "Removed from the list. Save to apply."),
    "savedEnabled": ("已保存，后台同步已启用。", "Saved. Scheduled sync is on."),
    "savedDisabled": ("已保存，后台同步已关闭。", "Saved. Scheduled sync is off."),
    "syncingAll": ("正在同步所有已启用路径…", "Syncing all enabled folders…"),
    "syncingPair": ("正在同步所选路径…", "Syncing the selected folder…"),
    "doneAll": ("所有已启用路径同步完成。", "All enabled folders are synced."),
    "donePair": ("所选路径同步完成。", "Selected folder is synced."),
    "error": ("操作失败", "Operation failed"),
    "resolving": ("正在处理冲突…", "Resolving conflict…"),
    "resolved": ("冲突已处理；两侧原件已备份。", "Conflict resolved. Both originals were backed up."),
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
    "directionHint": ("发现不同版本时暂停该文件，并在下方列出待处理冲突。", "Differing versions pause that file and appear below for review."),
    "conflicts": ("待处理冲突", "Pending conflicts"),
    "noConflicts": ("当前没有待处理冲突。", "No pending conflicts."),
    "viewLocal": ("查看本地", "Show local"),
    "viewCloud": ("查看云端", "Show cloud"),
    "resolve": ("选择版本", "Choose version"),
    "useLocal": ("采用本地版本", "Use local version"),
    "useCloud": ("采用云端版本", "Use cloud version"),
    "keepBoth": ("保留两份（本地为主文件）", "Keep both (local as main file)"),
    "conflictHint": ("处理前会把两侧原件备份到本机的 merge-state 目录。若文件在选择后发生变化，请先重新同步。", "Both originals are backed up locally under merge-state before resolution. Sync again if a file has changed since it was listed."),
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
    case 8: return "Some folders need attention. Review pending conflicts or open the log."
    case 9: return "Enable at least one folder before turning on scheduled sync."
    case 10: return "The folder paths no longer match their conflict records. Check this pair's paths."
    case 12: return "The conflict could not be resolved. Sync again if a file changed, then open the log for details."
    default: return "The operation did not complete. Open the log for details."
    }
}
