import AppKit
import Foundation

@main
struct MenuBarPopoverChecks {
    @MainActor private static func waitFor(_ message: String,
                                          condition: @escaping () -> Bool,
                                          then continuation: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(2)
        func poll() {
            if condition() { continuation(); return }
            assert(Date() < deadline, message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { poll() }
        }
        poll()
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var config = SyncConfig()
        config.pairs = [SyncPair(name: "Popover test", localPath: "/preview/local",
                                cloudPath: "/preview/cloud", enabled: true)]
        let model = SyncModel(testConfig: config)
        let menu = MenuBarController(model: model)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            fputs("Popover integration check timed out\n", stderr)
            menu.stop()
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            assert(menu.statusButton?.window != nil)
            menu.statusButton?.performClick(nil)
            waitFor("native status-button click must open a real visible popup",
                    condition: { menu.isPopoverShown && menu.popoverWindow?.isVisible == true }) {
                assert((menu.popoverWindow?.frame.width ?? 0) >= 356)
                if let view = menu.popoverWindow?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: CommandLine.arguments[1]))
                }
                model.busy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    assert(menu.isPopoverShown)
                    menu.statusButton?.performClick(nil)
                    waitFor("another click must close the popup while its icon animates",
                            condition: { !menu.isPopoverShown }) {
                        model.busy = false
                        app.setActivationPolicy(.accessory)
                        menu.statusButton?.performClick(nil)
                        waitFor("the popup must reopen in background/accessory mode",
                                condition: { menu.isPopoverShown && menu.popoverWindow?.isVisible == true }) {
                            menu.closePopover()
                            waitFor("programmatic close must complete",
                                    condition: { !menu.isPopoverShown }) {
                                menu.stop()
                                print("Native click, real popup visibility, close during animation, and reopen in background mode passed.")
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
        app.run()
    }
}
