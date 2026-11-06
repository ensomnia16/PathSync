import AppKit
import Combine
import SwiftUI

/// The click target is a native status-bar button. Its label is only an image;
/// animation never replaces the control or its popover presentation context.
@MainActor
final class MenuBarController: NSObject {
    private let model: SyncModel
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingController<MenuBarPanel>?
    private var modelChanges: AnyCancellable?
    private var animationTimer: Timer?
    private var outsideClickMonitor: Any?
    private var localDismissMonitor: Any?
    private var phase = 0

    init(model: SyncModel) {
        self.model = model
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: 30)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        // Own dismissal explicitly: a transient popover can dismiss on the
        // status-button mouse-down before its action then reopens it.
        popover.behavior = .applicationDefined
        popover.animates = true
        let content = MenuBarPanel(model: model, closeMenuBar: { [weak self] in self?.closePopover() })
        let host = NSHostingController(rootView: content)
        hosting = host
        popover.contentViewController = host
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
        update()
    }

    var statusButton: NSStatusBarButton? { statusItem?.button }
    var isPopoverShown: Bool { popover.isShown }
    var popoverWindow: NSWindow? { hosting?.view.window }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else if let button = statusItem?.button {
            model.refreshSyncActivity()
            update()
            resizePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            installDismissMonitors()
            model.refreshState()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localDismissMonitor { NSEvent.removeMonitor(localDismissMonitor) }
        outsideClickMonitor = nil
        localDismissMonitor = nil
    }

    private func installDismissMonitors() {
        guard outsideClickMonitor == nil, localDismissMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closePopover() }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePopover(); return nil }
            } else if event.window !== self.popoverWindow && event.window !== self.statusItem?.button?.window {
                self.closePopover()
            }
            return event
        }
    }

    private func resizePopover() {
        guard let host = hosting else { return }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        popover.contentSize = NSSize(width: 356, height: max(80, size.height))
    }

    private func update() {
        let state = model.menuBarState
        let title = model.t("appName") + " — " + model.t(state.titleKey)
        statusItem?.button?.image = menuBarIcon(for: state, phase: phase)
        statusItem?.button?.toolTip = title
        statusItem?.button?.setAccessibilityLabel(title)
        if state == .syncing, animationTimer == nil {
            let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.model.menuBarState == .syncing else { return }
                    self.phase = (self.phase + 1) % 12
                    self.statusItem?.button?.image = menuBarIcon(for: .syncing, phase: self.phase)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if state != .syncing {
            animationTimer?.invalidate()
            animationTimer = nil
            phase = 0
        }
        if popover.isShown {
            DispatchQueue.main.async { [weak self] in self?.resizePopover() }
        }
    }

    func stop() {
        closePopover()
        animationTimer?.invalidate()
        animationTimer = nil
        modelChanges?.cancel()
        modelChanges = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}
