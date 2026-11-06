import AppKit

enum RepairMode: String, Codable, CaseIterable, Identifiable {
    case smooth, texture, clone
    var id: String { rawValue }
    var title: String { switch self { case .smooth: L10n.text("平滑"); case .texture: L10n.text("纹理"); case .clone: L10n.text("取样") } }
}

extension CaptureRepair {
    static func texturePatch(_ image: CGImage, normalized a: CGPoint, _ b: CGPoint, anchor: CGPoint? = nil) -> CGImage? {
        let rect = CGRect(x: min(a.x, b.x) * CGFloat(image.width), y: (1 - max(a.y, b.y)) * CGFloat(image.height),
            width: abs(a.x - b.x) * CGFloat(image.width), height: abs(a.y - b.y) * CGFloat(image.height)).integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var source: CGRect?
        if let anchor {
            let point = CGPoint(x: anchor.x * CGFloat(image.width), y: (1 - anchor.y) * CGFloat(image.height))
            let candidate = CGRect(x: point.x - rect.width / 2, y: point.y - rect.height / 2, width: rect.width, height: rect.height).integral
            if bounds.contains(candidate) { source = candidate }
        } else {
            let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
            let w = max(1, Int(CGFloat(image.width) * scale)), h = max(1, Int(CGFloat(image.height) * scale))
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            func color(_ x: CGFloat, _ y: CGFloat, _ channel: Int) -> Double {
                let px = min(w - 1, max(0, Int(x * scale))), py = min(h - 1, max(0, h - 1 - Int(y * scale)))
                return Double(pixels[(py * w + px) * 4 + channel])
            }
            var score = Double.infinity
            for direction in 0..<8 {
                let angle = Double(direction) * .pi / 4
                for radius in [1.1, 1.6, 2.2, 3.0] {
                    let candidate = rect.offsetBy(dx: cos(angle) * rect.width * radius, dy: sin(angle) * rect.height * radius)
                    guard bounds.contains(candidate), !candidate.intersects(rect) else { continue }
                    var cost = 0.0
                    for edge in 0..<4 { for point in 1...12 {
                        let t = CGFloat(point) / 13
                        let x = edge < 2 ? rect.minX + rect.width * t : edge == 2 ? rect.minX - 1 : rect.maxX + 1
                        let y = edge >= 2 ? rect.minY + rect.height * t : edge == 0 ? rect.minY - 1 : rect.maxY + 1
                        let sx = x + candidate.minX - rect.minX, sy = y + candidate.minY - rect.minY
                        for channel in 0..<3 { let d = color(x, y, channel) - color(sx, sy, channel); cost += d * d }
                    } }
                    if cost < score { score = cost; source = candidate }
                }
            }
        }
        guard let source, let patch = image.cropping(to: source) else { return self.patch(image, normalized: a, b) }
        return patch
    }
}
