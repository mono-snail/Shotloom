import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let artworkURL = root.appendingPathComponent("Resources/AppIconArtwork.png")
guard let artwork = NSImage(contentsOf: artworkURL) else {
    fatalError("Missing capture mascot artwork: \(artworkURL.path)")
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: CGRect(x: 56, y: 56, width: 912, height: 912), xRadius: 214, yRadius: 214)
    NSGradient(starting: NSColor(calibratedRed: 0.96, green: 0.94, blue: 1, alpha: 1),
               ending: NSColor(calibratedRed: 0.84, green: 0.79, blue: 0.95, alpha: 1))!.draw(in: tile, angle: -65)
    if pixels <= 32 {
        // Keep the expression readable at Finder's smallest sizes.
        let face = NSBezierPath(roundedRect: CGRect(x: 245, y: 245, width: 534, height: 550), xRadius: 110, yRadius: 110)
        NSColor(calibratedRed: 1, green: 0.98, blue: 0.94, alpha: 1).setFill(); face.fill()
        let corners = NSBezierPath(); corners.lineWidth = 85; corners.lineCapStyle = .round; corners.lineJoinStyle = .round
        for (x, y, dx, dy) in [(CGFloat(235), CGFloat(245), CGFloat(1), CGFloat(1)), (789, 245, -1, 1),
                                (235, 795, 1, -1), (789, 795, -1, -1)] {
            corners.move(to: CGPoint(x: x, y: y + dy * 120)); corners.line(to: CGPoint(x: x, y: y)); corners.line(to: CGPoint(x: x + dx * 120, y: y))
        }
        NSColor(calibratedRed: 0.53, green: 0.39, blue: 0.84, alpha: 1).setStroke(); corners.stroke()
        NSColor(calibratedRed: 0.23, green: 0.17, blue: 0.32, alpha: 1).setFill()
        for x in [CGFloat(410), 614] { NSBezierPath(ovalIn: CGRect(x: x - 31, y: 535, width: 62, height: 76)).fill() }
        let smile = NSBezierPath(); smile.lineWidth = 38; smile.lineCapStyle = .round
        smile.move(to: CGPoint(x: 419, y: 455))
        smile.curve(to: CGPoint(x: 605, y: 455), controlPoint1: CGPoint(x: 457, y: 365), controlPoint2: CGPoint(x: 567, y: 365))
        NSColor(calibratedRed: 0.23, green: 0.17, blue: 0.32, alpha: 1).setStroke(); smile.stroke()
    } else {
        NSGraphicsContext.current?.imageInterpolation = .high
        artwork.draw(in: CGRect(x: 69, y: 38, width: 886, height: 886),
                     from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name + ".png"))
}
