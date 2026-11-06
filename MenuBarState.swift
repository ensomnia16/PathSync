import AppKit

enum SyncMenuBarState: String, CaseIterable {
    case disabled, syncing, enabled

    static func resolve(scheduleEnabled: Bool, hasEnabledPairs: Bool,
                        uiBusy: Bool, workerRunning: Bool) -> Self {
        if uiBusy || workerRunning { return .syncing }
        return scheduleEnabled && hasEnabledPairs ? .enabled : .disabled
    }

    var titleKey: String { "menubarState" + rawValue.capitalized }
}

private let menuBarIcons: [SyncMenuBarState: [NSImage]] = Dictionary(
    uniqueKeysWithValues: SyncMenuBarState.allCases.map { state in
      let frames = (0..<(state == .syncing ? 12 : 1)).map { phase in
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let cabinet = NSBezierPath(roundedRect: NSRect(x: 2, y: 1.5, width: 12.5, height: 15),
                                       xRadius: 2, yRadius: 2)
            cabinet.lineWidth = 1.5
            cabinet.stroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 2.75, y: 9))
            divider.line(to: NSPoint(x: 13.75, y: 9))
            divider.lineWidth = 1.25
            divider.stroke()
            NSColor.black.setFill()
            for y in [5.0, 12.0] {
                NSBezierPath(roundedRect: NSRect(x: 5.75, y: y, width: 5, height: 1.6),
                             xRadius: 0.8, yRadius: 0.8).fill()
            }
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            if state == .disabled {
                // Cut a gap first, so the slash reads on every menu-bar color.
                for (width, clear) in [(3.5, true), (1.6, false)] {
                    context.setBlendMode(clear ? .clear : .normal)
                    let slash = NSBezierPath()
                    slash.move(to: NSPoint(x: 0.75, y: 1))
                    slash.line(to: NSPoint(x: 16.75, y: 17))
                    slash.lineWidth = width
                    slash.lineCapStyle = .round
                    slash.stroke()
                }
            } else {
                let badge = NSRect(x: 11.75, y: 0, width: 10, height: 10)
                context.setBlendMode(.clear)
                context.fillEllipse(in: badge)
                context.setBlendMode(.normal)
                let symbol = state == .syncing ? "arrow.triangle.2.circlepath" : "checkmark"
                context.saveGState()
                context.translateBy(x: badge.midX, y: badge.midY)
                if state == .syncing { context.rotate(by: -CGFloat(phase) * .pi / 6) }
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))?
                    .draw(in: NSRect(x: -4.4, y: -4.4, width: 8.8, height: 8.8),
                          from: .zero, operation: .sourceOver, fraction: 1)
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
      }
      return (state, frames)
    })

func menuBarIcon(for state: SyncMenuBarState, phase: Int = 0) -> NSImage {
    let frames = menuBarIcons[state]!
    return frames[(phase % frames.count + frames.count) % frames.count]
}
