import AppKit

// The approved master remains square and unmasked. This raster wrapper is only
// for the existing .icns delivery path, which predates Icon Composer assets.
guard CommandLine.arguments.count == 3,
      let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024,
          pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Usage: package-legacy-icon.swift MASTER.png OUTPUT.png\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true
let bounds = NSRect(x: 96, y: 96, width: 832, height: 832)
let mask = NSBezierPath(roundedRect: bounds, xRadius: 182, yRadius: 182)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
shadow.shadowOffset = NSSize(width: 0, height: -6)
shadow.shadowBlurRadius = 14
shadow.set()
NSColor.white.setFill()
mask.fill()
NSShadow().set()
mask.addClip()
// Keep the white tile at the approved footprint, with a smaller cabinet inside.
let artworkBounds = bounds.insetBy(dx: bounds.width * 0.05, dy: bounds.height * 0.05)
source.draw(in: artworkBounds, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
let normalized = bitmap.converting(to: .sRGB, renderingIntent: .default) ?? bitmap
guard let png = normalized.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
