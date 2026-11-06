import AppKit

/// Matches a texture patch's low-frequency color to the clean pixels outside
/// the selection. Original pixels inside the selection are not boundary data.
enum RepairBoundaryBlend {
    static func apply(base: CGImage, repaired: CGImage, mask: RepairRasterMask) throws -> CGImage {
        try Task.checkCancellation()
        guard base.width == repaired.width, base.height == repaired.height,
              mask.width == base.width, mask.height == base.height,
              mask.values.count == mask.width * mask.height,
              let bounds = mask.bounds, let space = base.colorSpace, space.model == .rgb else {
            throw CaptureError.message(L10n.text("颜色融合需要有效的RGB图片和选区。"))
        }
        let area = bounds.insetBy(dx: -1, dy: -1).integral
            .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard area.width * area.height <= 262_144 else {
            throw CaptureError.message(L10n.text("选区超过颜色融合预算，请缩小选区或关闭边界颜色融合。"))
        }
        let width = Int(area.width), height = Int(area.height), count = width * height
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        func pixels(_ image: CGImage) throws -> [UInt8] {
            guard let crop = image.cropping(to: area),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: info) else {
                throw CaptureError.message(L10n.text("无法读取颜色融合区域。"))
            }
            context.setBlendMode(.copy)
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: count * 4))
            guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else {
                throw CaptureError.message(L10n.text("边界颜色融合用于不透明区域；透明边缘请关闭此选项。"))
            }
            return bytes
        }
        let original = try pixels(base)
        var replacement = try pixels(repaired)
        var selected = [Bool](repeating: false, count: count)
        for y in 0..<height { for x in 0..<width {
            selected[y * width + x] = mask.values[(y + Int(area.minY)) * mask.width + x + Int(area.minX)] > 0
        } }
        var correction = [SIMD3<Float>](repeating: .zero, count: count)
        var boundary = [Int](), interior = [[Int](), [Int]()]
        var total = SIMD3<Float>.zero
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<width where selected[y * width + x] {
                let index = y * width + x
                var target = SIMD3<Float>.zero, neighbors: Float = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let other = ny * width + nx
                    if !selected[other] {
                        let offset = other * 4
                        target += SIMD3(Float(original[offset]), Float(original[offset + 1]), Float(original[offset + 2]))
                        neighbors += 1
                    }
                }
                if neighbors > 0 {
                    let offset = index * 4
                    correction[index] = target / neighbors - SIMD3(Float(replacement[offset]), Float(replacement[offset + 1]), Float(replacement[offset + 2]))
                    boundary.append(index); total += correction[index]
                } else { interior[(x + y) % 2].append(index) }
            }
        }
        guard !boundary.isEmpty else {
            throw CaptureError.message(L10n.text("颜色融合需要保留周围未选中的背景，请缩小选区。"))
        }
        let mean = total / Float(boundary.count)
        for indices in interior { for index in indices { correction[index] = mean } }
        let interiorCount = interior[0].count + interior[1].count
        let iterations = min(600, 64_000_000 / max(1, interiorCount))
        var converged = interiorCount == 0
        for _ in 0..<iterations where !converged {
            try Task.checkCancellation()
            var largest: Float = 0
            for indices in interior {
                for (position, index) in indices.enumerated() {
                    if position % 1024 == 0 { try Task.checkCancellation() }
                    let x = index % width
                    var sum = SIMD3<Float>.zero, neighbors: Float = 0
                    if x > 0 { sum += correction[index - 1]; neighbors += 1 }
                    if x + 1 < width { sum += correction[index + 1]; neighbors += 1 }
                    if index >= width { sum += correction[index - width]; neighbors += 1 }
                    if index + width < count { sum += correction[index + width]; neighbors += 1 }
                    let delta = (sum / neighbors - correction[index]) * 1.7
                    correction[index] += delta
                    largest = max(largest, abs(delta.x), abs(delta.y), abs(delta.z))
                }
            }
            converged = largest < 0.01
        }
        guard converged else {
            throw CaptureError.message(L10n.text("颜色融合未在预算内收敛，请缩小选区或关闭此选项。"))
        }
        for index in 0..<count where selected[index] {
            if index % 1024 == 0 { try Task.checkCancellation() }
            for channel in 0..<3 {
                replacement[index * 4 + channel] = UInt8(max(0, min(255,
                    (Float(replacement[index * 4 + channel]) + correction[index][channel]).rounded())))
            }
        }
        let bytes = Data(replacement)
        guard let patch = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw CaptureError.message(L10n.text("无法创建颜色融合结果。"))
        }
        return try RepairPixelComposite.apply(base: repaired, patch: patch, rect: area, mask: mask)
    }
}
