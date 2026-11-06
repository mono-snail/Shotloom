import AppKit

struct OKLCHColor: Equatable {
    let lightness: Double
    let chroma: Double
    let hue: Double?
    var css: String { String(format: "oklch(%.3f%% %.5f %@)", lightness * 100, chroma, hue.map { String(format: "%.3f", $0) } ?? "none") }
}
struct RegionColorAnalysis {
    let average: CaptureColorSample
    let textCandidate: CaptureColorSample
    let backgroundCandidate: CaptureColorSample
    let minorityFraction: Double
}
enum CaptureColorAnalysis {
    static func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    static func encoded(_ value: Double) -> Double { value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055 }
    static func luminance(_ color: CaptureColorSample) -> Double {
        0.2126 * linear(Double(color.red) / 255) + 0.7152 * linear(Double(color.green) / 255) + 0.0722 * linear(Double(color.blue) / 255)
    }
    static func contrast(_ a: CaptureColorSample, _ b: CaptureColorSample) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func oklch(_ color: CaptureColorSample) -> OKLCHColor {
        let r = linear(Double(color.red) / 255), g = linear(Double(color.green) / 255), b = linear(Double(color.blue) / 255)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let opponentB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = hypot(a, opponentB), angle = atan2(opponentB, a) * 180 / .pi
        return .init(lightness: lightness, chroma: chroma, hue: chroma < 0.00001 ? nil : (angle + 360).truncatingRemainder(dividingBy: 360))
    }
    static func parse(_ hex: String) -> CaptureColorSample? {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6, raw.allSatisfy(\.isHexDigit), let value = UInt32(raw, radix: 16) else { return nil }
        return .init(red: Int((value >> 16) & 255), green: Int((value >> 8) & 255), blue: Int(value & 255))
    }
    /// Region uses normalized image coordinates, top-left. Average and clustering
    /// operate on linear sRGB, compositing transparent input on white first.
    static func region(_ image: CGImage, bounds: CGRect) throws -> RegionColorAnalysis {
        guard !bounds.isNull, !bounds.isInfinite, [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, CGRect(x: 0, y: 0, width: 1, height: 1).contains(bounds),
              let crop = image.cropping(to: CGRect(
                  x: floor(bounds.minX * CGFloat(image.width) + 0.000001),
                  y: floor(bounds.minY * CGFloat(image.height) + 0.000001),
                  width: max(1, ceil(bounds.maxX * CGFloat(image.width) - 0.000001) - floor(bounds.minX * CGFloat(image.width) + 0.000001)),
                  height: max(1, ceil(bounds.maxY * CGFloat(image.height) - 0.000001) - floor(bounds.minY * CGFloat(image.height) + 0.000001)))) else { throw CaptureError.message(L10n.text("请选择画面内的有效区域。")) }
        let scale = min(1, 512 / Double(max(crop.width, crop.height)))
        let w = max(1, Int(Double(crop.width) * scale)), h = max(1, Int(Double(crop.height) * scale))
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message(L10n.text("颜色采样失败。")) }
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let lookup = (0...255).map { linear(Double($0) / 255) }
        var centers = [0.0, 1.0], sums = [[Double]](repeating: [0, 0, 0], count: 2), counts = [Int](repeating: 0, count: 2)
        for _ in 0..<8 {
            try Task.checkCancellation(); sums = [[0, 0, 0], [0, 0, 0]]; counts = [0, 0]
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let r = lookup[Int(bytes[i])], g = lookup[Int(bytes[i + 1])], b = lookup[Int(bytes[i + 2])]
                let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let index = abs(y - centers[0]) <= abs(y - centers[1]) ? 0 : 1
                counts[index] += 1; sums[index][0] += r; sums[index][1] += g; sums[index][2] += b
            }
            for c in 0..<2 where counts[c] > 0 { centers[c] = (0.2126 * sums[c][0] + 0.7152 * sums[c][1] + 0.0722 * sums[c][2]) / Double(counts[c]) }
        }
        func color(_ sum: [Double], count: Int) -> CaptureColorSample {
            let rgb = sum.map { min(255, max(0, Int((encoded($0 / Double(max(1, count))) * 255).rounded()))) }
            return .init(red: rgb[0], green: rgb[1], blue: rgb[2])
        }
        let total = w * h, background = counts[0] >= counts[1] ? 0 : 1, ink = 1 - background
        let average = color((0..<3).map { sums[0][$0] + sums[1][$0] }, count: total)
        let bg = color(sums[background], count: counts[background])
        return .init(average: average, textCandidate: counts[ink] == 0 ? bg : color(sums[ink], count: counts[ink]),
                     backgroundCandidate: bg, minorityFraction: Double(counts[ink]) / Double(total))
    }
}
