import AppKit

// One continuous silhouette per arrow keeps the shaft and head joined cleanly.
// The blue tile is intentionally quiet so the bidirectional mark reads small.
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let tile = NSBezierPath(
    roundedRect: NSRect(x: 25, y: 25, width: 974, height: 974),
    xRadius: 216, yRadius: 216
)
NSGradient(starting: color(77, 132, 203), ending: color(34, 82, 154))!
    .draw(in: tile, angle: 90)
color(255, 255, 255, 0.22).setStroke()
tile.lineWidth = 3
tile.stroke()

func arrow() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 226, y: 649))
    path.curve(to: NSPoint(x: 664, y: 649),
               controlPoint1: NSPoint(x: 354, y: 670),
               controlPoint2: NSPoint(x: 538, y: 670))
    path.line(to: NSPoint(x: 664, y: 690))
    path.curve(to: NSPoint(x: 686, y: 698),
               controlPoint1: NSPoint(x: 664, y: 704),
               controlPoint2: NSPoint(x: 677, y: 707))
    path.line(to: NSPoint(x: 790, y: 641))
    path.curve(to: NSPoint(x: 790, y: 619),
               controlPoint1: NSPoint(x: 808, y: 630),
               controlPoint2: NSPoint(x: 808, y: 630))
    path.line(to: NSPoint(x: 686, y: 562))
    path.curve(to: NSPoint(x: 664, y: 570),
               controlPoint1: NSPoint(x: 677, y: 553),
               controlPoint2: NSPoint(x: 664, y: 556))
    path.line(to: NSPoint(x: 664, y: 606))
    path.curve(to: NSPoint(x: 226, y: 606),
               controlPoint1: NSPoint(x: 538, y: 627),
               controlPoint2: NSPoint(x: 354, y: 627))
    path.curve(to: NSPoint(x: 226, y: 649),
               controlPoint1: NSPoint(x: 193, y: 606),
               controlPoint2: NSPoint(x: 193, y: 649))
    path.close()
    return path
}

func paint(_ path: NSBezierPath, ink: NSColor) {
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.13)
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -7)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    ink.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
}

let upper = arrow()
paint(upper, ink: color(252, 251, 248))

let lower = arrow()
var turn = AffineTransform(translationByX: 1024, byY: 1024)
turn.rotate(byDegrees: 180)
lower.transform(using: turn)
paint(lower, ink: color(224, 239, 251))

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let destination = CommandLine.arguments.dropFirst().first ?? "PathSyncIcon.png"
try bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: destination))
