import AppKit

struct CompositionAnalysis {
    let focus: CGPoint // normalized, bottom-left
    let bounds: CGRect?
    let confident: Bool
}
enum SmartComposition {
    /// Input rows use image order (top-to-bottom), straight or opaque sRGB RGBA.
    static func analyze(width: Int, height: Int, rgba: [UInt8]) throws -> CompositionAnalysis {
        guard width > 0, height > 0, width <= 1024, height <= 1024, rgba.count == width * height * 4 else { throw CaptureError.message(L10n.text("构图采样无效。")) }
        let corners = [0, (width - 1) * 4, (height - 1) * width * 4, (width * height - 1) * 4]
        let background = (0..<3).map { c in corners.map { Int(rgba[$0 + c]) }.sorted()[2] }
        guard corners.allSatisfy({ i in (0..<3).allSatisfy { abs(Int(rgba[i + $0]) - background[$0]) <= 24 } }) else {
            return .init(focus: .init(x: 0.5, y: 0.5), bounds: nil, confident: false)
        }
        var count = 0, sumX = 0.0, sumY = 0.0, minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard rgba[offset + 3] > 16, (0..<3).contains(where: { abs(Int(rgba[offset + $0]) - background[$0]) > 24 }) else { continue }
                count += 1; sumX += Double(x) + 0.5; sumY += Double(y) + 0.5
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let fraction = Double(count) / Double(width * height)
        guard fraction >= 0.0005, fraction <= 0.85 else { return .init(focus: .init(x: 0.5, y: 0.5), bounds: nil, confident: false) }
        let bounds = CGRect(x: Double(minX) / Double(width), y: 1 - Double(maxY + 1) / Double(height),
                            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        let focus = CGPoint(x: 0.65 * sumX / Double(count * width) + 0.35 * bounds.midX,
                            y: 0.65 * (1 - sumY / Double(count * height)) + 0.35 * bounds.midY)
        return .init(focus: focus, bounds: bounds, confident: true)
    }
    static func analyze(_ image: CGImage) throws -> CompositionAnalysis {
        let scale = min(1, 1024 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var data = [UInt8](repeating: 255, count: w * h * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message(L10n.text("构图采样失败。")) }
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h)); context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return try analyze(width: w, height: h, rgba: data)
    }
    static func placement(image: CGSize, canvas: CGSize, focus: CGPoint) throws -> CGRect {
        guard [image.width, image.height, canvas.width, canvas.height, focus.x, focus.y].allSatisfy(\.isFinite),
              image.width > 0, image.height > 0, canvas.width >= image.width, canvas.height >= image.height,
              (0...1).contains(focus.x), (0...1).contains(focus.y) else { throw CaptureError.message(L10n.text("构图尺寸或重心无效。")) }
        return CGRect(x: min(canvas.width - image.width, max(0, (canvas.width / 2 - focus.x * image.width).rounded(.down))),
                      y: min(canvas.height - image.height, max(0, (canvas.height / 2 - focus.y * image.height).rounded(.down))),
                      width: image.width, height: image.height)
    }
}
