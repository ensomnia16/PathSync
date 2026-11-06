import Foundation
import Darwin
import CoreServices

private func fail(_ message: String) -> Never {
    #if !UPDATE_APPLY_TESTS
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ResearchSync/last-update-error.txt")
    try? message.write(to: file, atomically: true, encoding: .utf8)
    #endif
    fputs("PathSync update: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4,
      let parentPID = Int32(CommandLine.arguments[3]), parentPID > 0 else {
    fail("更新辅助程序参数无效。")
}

let fm = FileManager.default
let installed = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let staged = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
// Test fixtures must never read, replace or remove a real user's backup.
#if UPDATE_APPLY_TESTS
let backups = installed.deletingLastPathComponent().appendingPathComponent("test-update-backups")
#else
let backups = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ResearchSync/update-backups", isDirectory: true)
#endif
let previous = backups.appendingPathComponent("previous.bundle-backup", isDirectory: true)

for _ in 0..<600 {
    if kill(parentPID, 0) != 0 && errno == ESRCH { break }
    usleep(100_000)
}
guard kill(parentPID, 0) != 0 && errno == ESRCH else {
    fail("旧版应用没有退出，未替换安装包。")
}
guard fm.fileExists(atPath: staged.path), fm.fileExists(atPath: installed.path) else {
    fail("待安装版本或当前应用不存在。")
}

do {
    try fm.createDirectory(at: backups, withIntermediateDirectories: true)
    if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
    try fm.moveItem(at: installed, to: previous)
    do {
        try fm.moveItem(at: staged, to: installed)
    } catch {
        try? fm.moveItem(at: previous, to: installed)
        throw error
    }
    #if !UPDATE_APPLY_TESTS
    LSRegisterURL(installed as CFURL, true)
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-a", installed.path]
    try opener.run()
    opener.waitUntilExit()
    guard opener.terminationStatus == 0 else {
        try fm.removeItem(at: installed)
        try fm.moveItem(at: previous, to: installed)
        let retry = Process()
        retry.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        retry.arguments = ["-a", installed.path]
        try? retry.run()
        fail("无法打开新版应用，已恢复旧版。")
    }
    #endif
    #if !UPDATE_APPLY_TESTS
    let errorFile = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ResearchSync/last-update-error.txt")
    try? fm.removeItem(at: errorFile)
    #endif
    try? fm.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())
} catch {
    fail("安装失败：\(error.localizedDescription)")
}
