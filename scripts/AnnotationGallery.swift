// Offline visual QA for vector icons and mosaic presets; never captures the desktop.
import AppKit

@main
enum AnnotationGallery {
    static func main() throws {
        let sourceContext = CGContext(data: nil, width: 360, height: 220, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        sourceContext.setFillColor(NSColor.white.cgColor)
        sourceContext.fill(CGRect(x: 0, y: 0, width: 360, height: 220))
        sourceContext.setFillColor(NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.72, alpha: 1).cgColor)
        sourceContext.fill(CGRect(x: 0, y: 0, width: 360, height: 70))
        sourceContext.setFillColor(NSColor(calibratedRed: 0.93, green: 0.29, blue: 0.27, alpha: 1).cgColor)
        sourceContext.fill(CGRect(x: 24, y: 90, width: 190, height: 55))
        let source = sourceContext.makeImage()!
        let output = CGContext(data: nil, width: 1600, height: 610, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        output.setFillColor(NSColor(calibratedRed: 0.055, green: 0.09, blue: 0.14, alpha: 1).cgColor)
        output.fill(CGRect(x: 0, y: 0, width: 1600, height: 610))
        for (index, style) in MosaicStyle.allCases.enumerated() {
            let document = AnnotationDocument(image: source)
            document.mosaicStyle = style
            document.add(document.makeMark(tool: .mosaic, points: [CGPoint(x: 0.08, y: 0.16), CGPoint(x: 0.92, y: 0.84)]))
            let frame = CGRect(x: 28 + index * 394, y: 300, width: 360, height: 220)
            output.draw(document.render()!, in: frame)
            draw(style.title, at: CGPoint(x: frame.minX, y: 540), in: output)
        }
        for (index, icon) in VectorIcon.allCases.enumerated() {
            let document = AnnotationDocument(image: source)
            document.icon = icon
            document.selectColor(index.isMultiple(of: 2) ? .cyan : .coral)
            document.add(document.makeMark(tool: .icon, points: [CGPoint(x: 0.18, y: 0.14), CGPoint(x: 0.82, y: 0.9)]))
            let frame = CGRect(x: 30 + index * 195, y: 55, width: 168, height: 168)
            output.draw(document.render()!, in: frame)
            draw(icon.title, at: CGPoint(x: frame.minX, y: 237), in: output)
        }
        let path = CommandLine.arguments.dropFirst().first ?? "/tmp/deskcapture-annotation-gallery.png"
        let png = NSBitmapImageRep(cgImage: output.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: path))
        print(path)
    }
    static func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold),
                                                            .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
    }
}
