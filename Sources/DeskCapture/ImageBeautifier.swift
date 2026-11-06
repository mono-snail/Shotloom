import AppKit

enum BeautifyStyle: String, CaseIterable, Identifiable, Codable {
    case aurora, graphite, paper, ocean, sunset, iris, mint, rose, cobalt, sand, frost, forest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aurora: L10n.text("极光"); case .graphite: L10n.text("石墨"); case .paper: L10n.text("暖纸"); case .ocean: L10n.text("深海")
        case .sunset: L10n.text("落日"); case .iris: L10n.text("鸢尾"); case .mint: L10n.text("薄荷"); case .rose: L10n.text("玫瑰")
        case .cobalt: L10n.text("钴蓝"); case .sand: L10n.text("沙丘"); case .frost: L10n.text("冰川"); case .forest: L10n.text("森林")
        }
    }
    var colors: [NSColor] {
        switch self {
        case .aurora: [NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.38, alpha: 1),
                       NSColor(calibratedRed: 0.31, green: 0.20, blue: 0.47, alpha: 1),
                       NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.65, alpha: 1)]
        case .graphite: [NSColor(calibratedWhite: 0.05, alpha: 1),
                         NSColor(calibratedWhite: 0.16, alpha: 1),
                         NSColor(calibratedWhite: 0.07, alpha: 1)]
        case .paper: [NSColor(calibratedRed: 0.98, green: 0.92, blue: 0.83, alpha: 1),
                      NSColor(calibratedRed: 0.87, green: 0.79, blue: 0.76, alpha: 1),
                      NSColor(calibratedRed: 0.98, green: 0.89, blue: 0.75, alpha: 1)]
        case .ocean: palette((0.02, 0.10, 0.23), (0.03, 0.35, 0.55), (0.10, 0.65, 0.67))
        case .sunset: palette((0.30, 0.14, 0.44), (0.94, 0.36, 0.40), (1, 0.74, 0.38))
        case .iris: palette((0.13, 0.12, 0.34), (0.48, 0.32, 0.81), (0.76, 0.61, 0.95))
        case .mint: palette((0.75, 0.95, 0.89), (0.40, 0.78, 0.71), (0.10, 0.47, 0.45))
        case .rose: palette((0.99, 0.88, 0.92), (0.90, 0.53, 0.67), (0.51, 0.20, 0.42))
        case .cobalt: palette((0.07, 0.15, 0.42), (0.16, 0.34, 0.92), (0.52, 0.72, 1))
        case .sand: palette((0.94, 0.86, 0.72), (0.76, 0.59, 0.40), (0.52, 0.38, 0.27))
        case .frost: palette((0.96, 0.98, 1), (0.83, 0.90, 0.97), (0.67, 0.79, 0.90))
        case .forest: palette((0.04, 0.18, 0.15), (0.17, 0.40, 0.28), (0.55, 0.69, 0.40))
        }
    }
    private func palette(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ c: (CGFloat, CGFloat, CGFloat)) -> [NSColor] {
        [a, b, c].map { NSColor(calibratedRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    }
}

enum BeautifyLayout: String, CaseIterable, Identifiable, Codable {
    case original, square, landscape, portrait
    var id: String { rawValue }
    var title: String { switch self { case .original: L10n.text("原比例"); case .square: "1:1"; case .landscape: "16:9"; case .portrait: "9:16" } }
    var ratio: Double? { switch self { case .original: nil; case .square: 1; case .landscape: 16 / 9; case .portrait: 9 / 16 } }
}

enum CaptureBeautifier {
    struct CanvasGeometry {
        let width: Int
        let height: Int
        let padding: Int
    }

    /// Compute in source pixels before reducing a preview. Padding's 40/800px
    /// limits must not be recalculated from a smaller image.
    static func geometry(width: Int, height: Int, paddingPercent: Double, layout: BeautifyLayout) throws -> CanvasGeometry {
        guard width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
              paddingPercent.isFinite, (0...1).contains(paddingPercent) else {
            throw CaptureError.message(L10n.text("图片尺寸或背景留白参数无效。"))
        }
        let padding = paddingPercent == 0 ? 0 : max(40, min(800, Int(Double(min(width, height)) * paddingPercent)))
        var canvasWidth = width + 2 * padding, canvasHeight = height + 2 * padding
        if let ratio = layout.ratio {
            if Double(canvasWidth) / Double(canvasHeight) < ratio { canvasWidth = Int(ceil(Double(canvasHeight) * ratio)) }
            else { canvasHeight = Int(ceil(Double(canvasWidth) / ratio)) }
        }
        guard Double(canvasWidth) * Double(canvasHeight) <= 80_000_000 else {
            throw CaptureError.message(L10n.text("美化画布超过 8000 万像素，请减少留白或更换比例。"))
        }
        return .init(width: canvasWidth, height: canvasHeight, padding: padding)
    }

    static func render(_ image: CGImage, style: BeautifyStyle, paddingPercent: Double = 0.09,
                       roundness: Double = 0.27, layout: BeautifyLayout = .original, customBackground: CGImage? = nil,
                       contentFocus: CGPoint? = nil, maximumDimension: Int? = nil, watermark: ImageWatermark = .init()) throws -> CGImage {
        try Task.checkCancellation()
        guard paddingPercent.isFinite, roundness.isFinite, (0...1).contains(paddingPercent), (0...1).contains(roundness) else {
            throw CaptureError.message(L10n.text("背景留白或圆角参数无效。"))
        }
        let canvas = try geometry(width: image.width, height: image.height, paddingPercent: paddingPercent, layout: layout)
        if let maximumDimension, maximumDimension <= 0 { throw CaptureError.message(L10n.text("预览尺寸无效。")) }
        let factor = maximumDimension.map { min(1, Double($0) / Double(max(canvas.width, canvas.height))) } ?? 1
        let width = max(1, Int(Double(canvas.width) * factor)), height = max(1, Int(Double(canvas.height) * factor))
        let scaleX = CGFloat(width) / CGFloat(canvas.width), scaleY = CGFloat(height) / CGFloat(canvas.height)
        let scale = min(scaleX, scaleY), padding = CGFloat(canvas.padding) * scale
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: style.colors.map(\.cgColor) as CFArray,
                                        locations: [0, 0.52, 1]) else {
            throw CaptureError.message(L10n.text("图片过大，无法创建美化背景。"))
        }
        if let background = customBackground {
            let factor = max(CGFloat(width) / CGFloat(background.width), CGFloat(height) / CGFloat(background.height))
            context.interpolationQuality = .high
            context.draw(background, in: CGRect(x: (CGFloat(width) - CGFloat(background.width) * factor) / 2,
                                               y: (CGFloat(height) - CGFloat(background.height) * factor) / 2,
                                               width: CGFloat(background.width) * factor, height: CGFloat(background.height) * factor))
        } else { context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: []) }
        if style == .aurora && customBackground == nil {
            context.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
            context.fillEllipse(in: CGRect(x: -CGFloat(width) / 5, y: -CGFloat(height) / 2,
                                           width: CGFloat(width), height: CGFloat(height)))
        }
        let originalRect = try SmartComposition.placement(image: CGSize(width: image.width, height: image.height),
            canvas: CGSize(width: canvas.width, height: canvas.height), focus: contentFocus ?? CGPoint(x: 0.5, y: 0.5))
        let imageRect = originalRect.applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
        let radius = min(CGFloat(max(canvas.padding, 20)) * roundness, CGFloat(min(image.width, image.height)) / 4) * scale
        context.interpolationQuality = .high
        try Task.checkCancellation()
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -padding * 0.12),
                          blur: padding * 0.36, color: NSColor.black.withAlphaComponent(0.36).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath(); context.restoreGState()
        context.saveGState()
        context.addPath(CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip(); context.draw(image, in: imageRect)
        try watermark.draw(in: context, rect: imageRect, pixelScale: scale)
        context.restoreGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(style == .graphite ? 0.24 : 0.55).cgColor)
        context.setLineWidth(max(1, CGFloat(canvas.padding) * 0.02) * scale)
        context.addPath(CGPath(roundedRect: imageRect.insetBy(dx: -scaleX, dy: -scaleY),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw CaptureError.message(L10n.text("美化图片生成失败。")) }
        return output
    }
}
