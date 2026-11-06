import AppKit
import CryptoKit

struct ImageComparisonSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case wipe, blend, difference, sideBySide
        var id: String { rawValue }
        var title: String { switch self { case .wipe: L10n.text("滑动对照"); case .blend: L10n.text("透明叠加"); case .difference: L10n.text("像素差异"); case .sideBySide: L10n.text("左右并排") } }
    }
    var mode = Mode.wipe
    var split = 0.5
    var opacity = 0.5
    var scale = 1.0
    var offsetX = 0.0
    var offsetY = 0.0 // pixels, bottom-left canvas
    var threshold = 12
    func validate() throws {
        guard [split, opacity, scale, offsetX, offsetY].allSatisfy(\.isFinite), (0...1).contains(split), (0...1).contains(opacity),
              (0.25...4).contains(scale), abs(offsetX) <= 16000, abs(offsetY) <= 16000, (0...255).contains(threshold) else { throw CaptureError.message(L10n.text("对齐、缩放或差异参数无效。")) }
    }
}
struct ImageComparisonReport: Codable {
    let version: Int
    let settings: ImageComparisonSettings
    let width: Int
    let height: Int
    let changedPixels: Int
    let regionCount: Int
    let alignedBeforeSHA256: String
    let alignedAfterSHA256: String
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw CaptureError.message(L10n.text("对照设置超过16KB。")) }
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.version == 1, report.width > 0, report.height > 0, report.width <= 16_000, report.height <= 16_000,
              report.width * report.height <= 10_000_000, (0...(report.width * report.height)).contains(report.changedPixels),
              report.regionCount >= 0,
              [report.alignedBeforeSHA256, report.alignedAfterSHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else { throw CaptureError.message(L10n.text("对照设置或测量记录无效。")) }
        try report.settings.validate(); return report
    }
}
struct ImageComparisonResult {
    let image: CGImage
    let regions: [CGRect] // image-order pixels, top-left; first 200 components
    let report: ImageComparisonReport
}
enum ImageComparison {
    static func render(before: CGImage, after: CGImage, settings: ImageComparisonSettings) throws -> ImageComparisonResult {
        try settings.validate()
        let w = max(before.width, after.width), h = max(before.height, after.height)
        guard w > 0, h > 0, w <= 16_000, h <= 16_000, w * h <= 10_000_000 else { throw CaptureError.message(L10n.text("对照画布最多1000万像素，单边16000像素；请先缩小图片。")) }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        func context(width: Int = w) throws -> CGContext {
            guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message(L10n.text("无法分配对照画布。")) }
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: h)); return ctx
        }
        let a = try context(), b = try context()
        a.draw(before, in: CGRect(x: (w - before.width) / 2, y: (h - before.height) / 2, width: before.width, height: before.height))
        let scaled = CGSize(width: Double(after.width) * settings.scale, height: Double(after.height) * settings.scale)
        b.interpolationQuality = .high
        b.draw(after, in: CGRect(x: (Double(w) - scaled.width) / 2 + settings.offsetX,
                                y: (Double(h) - scaled.height) / 2 + settings.offsetY, width: scaled.width, height: scaled.height))
        guard let pa = a.data?.assumingMemoryBound(to: UInt8.self), let pb = b.data?.assumingMemoryBound(to: UInt8.self),
              let alignedA = a.makeImage(), let alignedB = b.makeImage() else { throw CaptureError.message(L10n.text("对照像素不可读。")) }
        let heat = try context(), ph = heat.data!.assumingMemoryBound(to: UInt8.self)
        let tile = 32, columns = (w + tile - 1) / tile, rows = (h + tile - 1) / tile
        var tiles = [Bool](repeating: false, count: columns * rows), changed = 0
        for y in 0..<h {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                let offset = (y * w + x) * 4
                let delta = max(abs(Int(pa[offset]) - Int(pb[offset])), abs(Int(pa[offset + 1]) - Int(pb[offset + 1])), abs(Int(pa[offset + 2]) - Int(pb[offset + 2])))
                ph[offset] = UInt8(min(255, delta * 4)); ph[offset + 1] = 0; ph[offset + 2] = 0; ph[offset + 3] = 255
                if delta > settings.threshold { changed += 1; tiles[(y / tile) * columns + x / tile] = true }
            }
        }
        var regions: [CGRect] = [], regionCount = 0
        for start in tiles.indices where tiles[start] {
            var queue = [start], cursor = 0, minX = columns, minY = rows, maxX = 0, maxY = 0
            tiles[start] = false
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1
                let x = index % columns, y = index / columns
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < columns, ny < rows else { continue }
                    let neighbor = ny * columns + nx
                    if tiles[neighbor] { tiles[neighbor] = false; queue.append(neighbor) }
                }
            }
            regionCount += 1
            if regions.count < 200 {
                regions.append(CGRect(x: minX * tile, y: minY * tile, width: min(w, (maxX + 1) * tile) - minX * tile,
                                      height: min(h, (maxY + 1) * tile) - minY * tile))
            }
        }
        let output = try context(width: settings.mode == .sideBySide ? w * 2 : w)
        switch settings.mode {
        case .wipe:
            output.draw(alignedA, in: canvas); output.saveGState()
            output.clip(to: CGRect(x: Double(w) * settings.split, y: 0, width: Double(w) * (1 - settings.split), height: Double(h)))
            output.draw(alignedB, in: canvas); output.restoreGState()
        case .blend:
            output.draw(alignedA, in: canvas); output.setAlpha(settings.opacity); output.draw(alignedB, in: canvas)
        case .difference:
            guard let image = heat.makeImage() else { throw CaptureError.message(L10n.text("差异图生成失败。")) }; output.draw(image, in: canvas)
        case .sideBySide:
            output.draw(alignedA, in: canvas); output.draw(alignedB, in: canvas.offsetBy(dx: CGFloat(w), dy: 0))
        }
        try Task.checkCancellation()
        guard let image = output.makeImage() else { throw CaptureError.message(L10n.text("对照输出失败。")) }
        func digest(_ pointer: UnsafeMutablePointer<UInt8>) -> String {
            SHA256.hash(data: Data(bytesNoCopy: pointer, count: w * h * 4, deallocator: .none)).map { String(format: "%02x", $0) }.joined()
        }
        let report = ImageComparisonReport(version: 1, settings: settings, width: w, height: h, changedPixels: changed,
            regionCount: regionCount, alignedBeforeSHA256: digest(pa), alignedAfterSHA256: digest(pb))
        return .init(image: image, regions: regions, report: report)
    }
    static func exportPNG(_ image: CGImage, to destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".DeskCapture-comparison-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: stage) }
        try SensitiveBatchIO.writeCleanPNG(image, to: stage)
        try beforeCommit?(); try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: destination) }
    }
}
