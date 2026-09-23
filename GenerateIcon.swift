import AppKit

// Two opposing, gently curved arrows are the complete mark.
// The modest depth of the blue tile keeps the icon distinct at Dock sizes.
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

func arrow(start: NSPoint, control1: NSPoint, control2: NSPoint,
           end: NSPoint, headUpper: NSPoint, headLower: NSPoint,
           ink: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = 67
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: start)
    path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
    path.move(to: headUpper)
    path.line(to: end)
    path.line(to: headLower)

    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.18)
    shadow.shadowBlurRadius = 17
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    ink.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

arrow(start: NSPoint(x: 244, y: 619),
      control1: NSPoint(x: 370, y: 696), control2: NSPoint(x: 610, y: 696),
      end: NSPoint(x: 766, y: 619),
      headUpper: NSPoint(x: 651, y: 713), headLower: NSPoint(x: 651, y: 525),
      ink: color(252, 251, 248))
arrow(start: NSPoint(x: 780, y: 405),
      control1: NSPoint(x: 654, y: 328), control2: NSPoint(x: 414, y: 328),
      end: NSPoint(x: 258, y: 405),
      headUpper: NSPoint(x: 373, y: 499), headLower: NSPoint(x: 373, y: 311),
      ink: color(219, 237, 250))

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let destination = CommandLine.arguments.dropFirst().first ?? "PathSyncIcon.png"
try bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: destination))
