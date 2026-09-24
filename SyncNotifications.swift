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
