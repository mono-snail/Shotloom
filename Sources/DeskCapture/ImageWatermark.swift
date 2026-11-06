import AppKit
import CoreText
import SwiftUI

struct ImageWatermark: Codable, Hashable, Sendable {
    var enabled = false
    var text = ""
    var fontName = ""
    var fontSize = 28.0
    var angle = -30.0
    var opacity = 0.18

    var active: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Draw in source-pixel units, so reduced previews and full-size exports agree.
    func draw(in context: CGContext, rect: CGRect, pixelScale: CGFloat = 1) throws {
        guard active else { return }
        guard fontSize.isFinite, angle.isFinite, opacity.isFinite, pixelScale > 0 else {
            throw CaptureError.message(L10n.text("水印参数无效。"))
        }
        try Task.checkCancellation()
        let size = CGFloat(min(96, max(12, fontSize))) * pixelScale
        let font = (fontName.isEmpty ? nil : NSFont(name: fontName, size: size)) ?? NSFont.systemFont(ofSize: size)
        let label = String(text.replacingOccurrences(of: "\n", with: " ").prefix(80))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
            .strokeColor: NSColor.white, .strokeWidth: -2
        ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let stepX = max(120 * pixelScale, width + size * 2.5)
        let stepY = max(80 * pixelScale, size * 3.5)
        // Rotate the viewport back to find just the rows and columns it intersects.
        let radians = CGFloat(min(90, max(-90, angle))) * .pi / 180
        let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
            .applying(CGAffineTransform(rotationAngle: -radians))
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: radians)
        context.setAlpha(CGFloat(min(1, max(0.05, opacity))))
        context.textMatrix = .identity
        let firstRow = Int(floor(local.minY / stepY)) - 1
        let lastRow = Int(ceil(local.maxY / stepY)) + 1
        for row in firstRow...lastRow {
            try Task.checkCancellation()
            let offset = row.isMultiple(of: 2) ? CGFloat.zero : stepX / 2
            let first = Int(floor((local.minX - offset - width) / stepX))
            let last = Int(ceil((local.maxX - offset) / stepX))
            for column in first...last {
                context.textPosition = CGPoint(x: CGFloat(column) * stepX + offset, y: CGFloat(row) * stepY)
                CTLineDraw(line, context)
            }
        }
    }

    func validate() throws {
        guard active, text.count <= 80, fontName.utf8.count <= 256,
              fontSize.isFinite, (12...96).contains(fontSize), angle.isFinite, (-90...90).contains(angle),
              opacity.isFinite, (0.05...0.6).contains(opacity) else {
            throw CaptureError.message(L10n.text("请填写水印文字，并检查字号、角度和透明度。"))
        }
    }

    func applying(to image: CGImage) throws -> CGImage {
        try validate()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("无法创建水印画布。"))
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        try draw(in: context, rect: rect)
        guard let result = context.makeImage() else { throw CaptureError.message(L10n.text("水印生成失败。")) }
        return result
    }

}

struct WatermarkFields: View {
    @Binding var value: ImageWatermark
    var compact = false
    var body: some View {
        InspectorField(title: L10n.text("文字")) {
            TextField(L10n.text("输入水印文字"), text: $value.text)
                .onChange(of: value.text) { _, text in
                    if text.count > 80 { value.text = String(text.prefix(80)) }
                }
        }
        if compact { InspectorControlGrid { parameters } }
        else { parameters }
    }
    @ViewBuilder private var parameters: some View {
        InspectorField(title: L10n.text("字体")) {
            Picker(L10n.text("字体"), selection: $value.fontName) {
                Text(L10n.text("系统字体")).tag("")
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { Text($0).tag($0) }
            }
        }
        InspectorSlider(title: L10n.text("字号"), value: $value.fontSize, range: 12...96, unit: "px")
        InspectorSlider(title: L10n.text("角度"), value: $value.angle, range: -90...90, unit: "°")
        InspectorSlider(title: L10n.text("透明度"), value: $value.opacity, range: 0.05...0.6, scale: 100, unit: "%")
    }
}
