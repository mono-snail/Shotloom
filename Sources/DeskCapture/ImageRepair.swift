import AppKit

enum CaptureRepair {
    // Reconstruct the selected area from its surrounding pixels. Work at a
    // bounded resolution; source pixels inside the selection are never reused.
    static func patch(_ image: CGImage, normalized a: CGPoint, _ b: CGPoint) -> CGImage? {
        let rect = CGRect(x: min(a.x, b.x) * CGFloat(image.width), y: (1 - max(a.y, b.y)) * CGFloat(image.height),
                          width: abs(a.x - b.x) * CGFloat(image.width), height: abs(a.y - b.y) * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = min(1, 320 / max(rect.width, rect.height))
        let w = max(2, Int(rect.width * scale)), h = max(2, Int(rect.height * scale))
        let extended = rect.insetBy(dx: -max(2, 1 / scale), dy: -max(2, 1 / scale))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let surrounding = image.cropping(to: extended) else { return nil }
        var input = [UInt8](repeating: 0, count: (w + 2) * (h + 2) * 4)
        let success = input.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w + 2, height: h + 2, bitsPerComponent: 8,
                                          bytesPerRow: (w + 2) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(surrounding, in: CGRect(x: 0, y: 0, width: w + 2, height: h + 2)); return true
        }
        guard success else { return nil }
        var output = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let top = ((x + 1) * 4), bottom = (((h + 1) * (w + 2) + x + 1) * 4)
                let left = ((y + 1) * (w + 2) * 4), right = (((y + 1) * (w + 2) + w + 1) * 4)
                let tx = Double(x + 1) / Double(w + 1), ty = Double(y + 1) / Double(h + 1)
                // Blend the four boundary estimates with distance weights.
                let verticalWeight = 1 / max(0.02, ty * (1 - ty))
                let horizontalWeight = 1 / max(0.02, tx * (1 - tx))
                for channel in 0..<3 {
                    let vertical = Double(input[top + channel]) * (1 - ty) + Double(input[bottom + channel]) * ty
                    let horizontal = Double(input[left + channel]) * (1 - tx) + Double(input[right + channel]) * tx
                    output[(y * w + x) * 4 + channel] = UInt8(max(0, min(255,
                        ((vertical * verticalWeight + horizontal * horizontalWeight) / (verticalWeight + horizontalWeight)).rounded())))
                }
            }
        }
        let provider = CGDataProvider(data: Data(output) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    static func foreground(_ image: CGImage, bounds: CGRect) -> NSColor {
        let rect = CGRect(x: bounds.minX * CGFloat(image.width), y: (1 - bounds.maxY) * CGFloat(image.height),
                          width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height)).integral
        guard let crop = image.cropping(to: rect), let background = patch(image, normalized: bounds.origin,
            CGPoint(x: bounds.maxX, y: bounds.maxY)) else { return .black }
        func pixels(_ source: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 64 * 16 * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 64, height: 16, bitsPerComponent: 8, bytesPerRow: 256,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(source, in: CGRect(x: 0, y: 0, width: 64, height: 16))
            }
            return data
        }
        let source = pixels(crop), back = pixels(background)
        var best = 0, distance = -1
        for index in stride(from: 0, to: source.count, by: 4) {
            let score = (0..<3).reduce(0) { $0 + abs(Int(source[index + $1]) - Int(back[index + $1])) }
            if score > distance { best = index; distance = score }
        }
        return NSColor(srgbRed: Double(source[best]) / 255, green: Double(source[best + 1]) / 255,
                       blue: Double(source[best + 2]) / 255, alpha: 1)
    }
}
