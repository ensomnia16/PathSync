import AppKit
import Foundation
import UserNotifications

final class SyncNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }
}

let syncNotificationDelegate = SyncNotificationDelegate()

private final class NotificationTestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    func setFailure(_ text: String?) { lock.lock(); failure = text; lock.unlock() }
    func errorMessage() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
}

/// Diagnose app registration without performing a sync or requesting new permissions.
func postIconTestNotification(language: String) throws {
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)
    let outcome = NotificationTestOutcome()
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            outcome.setFailure(uiText("notificationDenied", language: language))
            done.signal()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = usesEnglish(language) ? "PathSync icon test" : "路径同步图标测试"
        content.body = usesEnglish(language) ? "Test notification only. No files were synchronized." : "这是一条测试通知，没有执行文件同步。"
        center.add(UNNotificationRequest(identifier: "pathsync.icon-test." + UUID().uuidString,
                                         content: content, trigger: nil)) { error in
            outcome.setFailure(error?.localizedDescription)
            done.signal()
        }
    }
    guard done.wait(timeout: .now() + 5) == .success else {
        throw NSError(domain: "PathSync.NotificationTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Notification submission timed out."])
    }
    if let message = outcome.errorMessage() {
        throw NSError(domain: "PathSync.NotificationTest", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
}

func syncHadNewIssue(_ output: String, failed: Bool) -> Bool {
    if failed { return true }
    for component in output.components(separatedBy: "kept_both=").dropFirst() {
        if Int(component.prefix(while: \.isNumber)) ?? 0 > 0 { return true }
    }
    return false
}

func postSyncNotification(config: SyncConfig, output: String, failed: Bool) {
    let issue = syncHadNewIssue(output, failed: failed)
    guard config.notificationMode == "all" || (config.notificationMode == "issues" && issue) else { return }

    let center = UNUserNotificationCenter.current()
    let completion = DispatchSemaphore(value: 0)
    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            completion.signal()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = uiText(issue ? "notificationIssueTitle" : "notificationDoneTitle", language: config.language)
        content.body = uiText(issue ? "notificationIssueBody" : "notificationDoneBody", language: config.language)
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in
            completion.signal()
        }
    }
    // The scheduled command exits after syncing, so wait briefly for Notification Center to accept the request.
    _ = completion.wait(timeout: .now() + 5)
}
