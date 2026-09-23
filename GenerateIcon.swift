import AppKit

// A deliberately flat, two-folder mark. Keep the silhouette readable at 16 px.
let side = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

let background = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 210, yRadius: 210)
color(37, 62, 51).setFill()
background.fill()

func folder(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, fill: NSColor) {
    let body = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 43, yRadius: 43)
    let tab = NSBezierPath(roundedRect: NSRect(x: x, y: y + height - 3, width: width * 0.43, height: 83), xRadius: 30, yRadius: 30)
    fill.setFill()
    body.fill()
    tab.fill()
}

folder(x: 160, y: 320, width: 440, height: 370, fill: color(245, 239, 224))
folder(x: 424, y: 260, width: 440, height: 370, fill: color(202, 102, 72))

// The short bridge is the only sync cue; it remains visible at small Dock sizes.
let bridge = NSBezierPath()
bridge.lineWidth = 36
bridge.lineCapStyle = .round
bridge.move(to: NSPoint(x: 355, y: 468))
bridge.line(to: NSPoint(x: 668, y: 468))
color(37, 62, 51).setStroke()
bridge.stroke()

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let destination = CommandLine.arguments.dropFirst().first ?? "PathSyncIcon.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
