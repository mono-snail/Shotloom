import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

struct SensitiveBatchPage: Identifiable {
    let id = UUID()
    let snapshot: URL
    let width: Int
    let height: Int
    var candidates: [SensitiveReviewCandidate] = []
    var selected = Set<UUID>()
    var manualBounds: [CGRect] = []
    var scanned = false
    var reviewed = false
    var redactions: [CGRect] {
        candidates.filter { selected.contains($0.id) }.map(\.line.bounds) + manualBounds
    }
}

enum SensitiveBatchIO {
    static func read(_ url: URL) throws -> CGImage {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 512_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_000, height <= 16_000, width * height <= 32_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CaptureError.message(L10n.text("需为单帧图片，最多3200万像素、单边16000像素。")) }
        return image
    }
    /// Rebuild only visible pixels into an opaque raster. Never copy source properties,
    /// editable project data, text chunks, transparent hidden pixels or thumbnails.
    static func flattened(_ image: CGImage, bounds: [CGRect]) throws -> CGImage {
        guard image.width > 0, image.height > 0, image.width <= 16_000, image.height <= 16_000,
              image.width * image.height <= 32_000_000, bounds.count <= 5000,
              bounds.allSatisfy({ !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 &&
                  [$0.minX, $0.minY, $0.maxX, $0.maxY].allSatisfy(\.isFinite) }),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CaptureError.message(L10n.text("脱敏范围或图片超过处理预算。"))
        }
        let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(NSColor.white.cgColor); context.fill(canvas)
        context.draw(image, in: canvas)
        context.setShouldAntialias(false); context.setFillColor(NSColor.black.cgColor)
        for bounds in bounds {
            try Task.checkCancellation()
            let pixels = CGRect(x: bounds.minX * canvas.width, y: bounds.minY * canvas.height,
                                width: bounds.width * canvas.width, height: bounds.height * canvas.height)
                .insetBy(dx: -3, dy: -3).integral.intersection(canvas)
            if !pixels.isEmpty { context.fill(pixels) }
        }
        guard let result = context.makeImage() else { throw CaptureError.message(L10n.text("无法渲染脱敏副本。")) }
        return result
    }
    static func writeCleanPNG(_ image: CGImage, to url: URL) throws {
        let encoded = url.deletingLastPathComponent().appendingPathComponent(".DeskCapture-png-\(UUID()).png")
        let pixels = url.deletingLastPathComponent().appendingPathComponent(".DeskCapture-pixels-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: encoded); try? FileManager.default.removeItem(at: pixels) }
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(encoded as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.message(L10n.text("无法创建脱敏PNG。"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message(L10n.text("脱敏PNG写入失败。")) }
        // ImageIO synthesizes an eXIf chunk even with nil properties. Keep only
        // pixel structure and standard sRGB transfer information, streaming IDAT.
        try copyPixelChunks(encoded, to: pixels)
        try Task.checkCancellation()
        guard Darwin.rename(pixels.path, url.path) == 0 else { throw CaptureError.message(L10n.text("脱敏PNG提交失败，原目标保持。")) }
    }
    private static func copyPixelChunks(_ source: URL, to destination: URL) throws {
        let length = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard length >= 20, length <= 512_000_000 else { throw CaptureError.message(L10n.text("脱敏PNG大小异常。")) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CaptureError.message(L10n.text("无法创建像素PNG。")) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        func read(_ count: Int) throws -> Data {
            var value = Data()
            while value.count < count {
                guard let part = try input.read(upToCount: count - value.count), !part.isEmpty else { throw CaptureError.message(L10n.text("PNG数据提前结束。")) }
                value.append(part)
            }
            return value
        }
        let signature = try read(8)
        guard signature == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw CaptureError.message(L10n.text("PNG签名异常。")) }
        try output.write(contentsOf: signature)
        let keep = Set(["IHDR", "PLTE", "IDAT", "IEND", "sRGB", "gAMA", "cHRM"])
        var offset = 8, chunks = 0, hasPixels = false, finished = false
        while offset + 12 <= length {
            try Task.checkCancellation(); chunks += 1
            guard chunks <= 100_000 else { throw CaptureError.message(L10n.text("PNG块数超预算。")) }
            let header = try read(8)
            let count = header.prefix(4).reduce(0) { $0 * 256 + Int($1) }
            guard count <= length - offset - 12 else { throw CaptureError.message(L10n.text("PNG块范围异常。")) }
            let name = String(decoding: header.suffix(4), as: UTF8.self)
            if keep.contains(name) {
                try output.write(contentsOf: header)
                var remaining = count + 4 // Include the original CRC unchanged.
                while remaining > 0 {
                    try Task.checkCancellation()
                    let amount = min(1_048_576, remaining)
                    try output.write(contentsOf: read(amount)); remaining -= amount
                }
            } else { try input.seek(toOffset: UInt64(offset + count + 12)) }
            hasPixels = hasPixels || name == "IDAT"; offset += count + 12
            if name == "IEND" { finished = true; break }
        }
        guard finished, hasPixels, offset == length else { throw CaptureError.message(L10n.text("PNG像素数据不完整。")) }
    }
    static func importPages(_ urls: [URL], into root: URL) throws -> [SensitiveBatchPage] {
        guard !urls.isEmpty, urls.count <= 20 else { throw CaptureError.message(L10n.text("一次选择1–20张图片。")) }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw CaptureError.message(L10n.text("临时目录已存在，未复用或清理。")) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: root) } }
        var pages: [SensitiveBatchPage] = [], pixels = 0
        for url in urls {
            try Task.checkCancellation()
            let page: SensitiveBatchPage = try autoreleasepool {
                let image = try read(url)
                pixels += image.width * image.height
                guard pixels <= 128_000_000 else { throw CaptureError.message(L10n.text("批次总像素不能超过1.28亿，请分批处理。")) }
                let snapshot = root.appendingPathComponent("\(UUID()).png")
                try writeCleanPNG(flattened(image, bounds: []), to: snapshot)
                return SensitiveBatchPage(snapshot: snapshot, width: image.width, height: image.height)
            }
            pages.append(page)
        }
        committed = true; return pages
    }
    static func export(_ pages: [SensitiveBatchPage], to destination: URL,
                       beforeCommit: (() throws -> Void)? = nil) throws {
        guard !pages.isEmpty, pages.count <= 20, pages.allSatisfy({ $0.scanned && $0.reviewed }) else {
            throw CaptureError.message(L10n.text("请先逐张检查并确认复核完成。"))
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw CaptureError.message(L10n.text("目标目录已存在，未覆盖。")) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".DeskCapture-redacted-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let source = try read(page.snapshot)
                let image = try flattened(source, bounds: page.redactions)
                try writeCleanPNG(image, to: stage.appendingPathComponent(String(format: "redacted-%03d.png", index + 1)))
            }
        }
        try beforeCommit?()
        try Task.checkCancellation()
        // Single directory rename is the commit boundary. Cancellation before this
        // point removes the stage; after commit the complete batch is delivered.
        try manager.moveItem(at: stage, to: destination)
    }
}

@MainActor
final class SensitiveBatchModel: ObservableObject {
    @Published var pages: [SensitiveBatchPage] = []
    @Published var busy = false
    @Published var status = L10n.text("选择需要复核的图片；原文件和原工程独立保留。")
    @Published var error: String?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var ownedRoot: URL?
    func cancel() { generation = UUID(); worker?.cancel(); worker = nil; busy = false }
    func close() {
        cancel()
        if let root = ownedRoot { ownedRoot = nil; Task.detached { try? FileManager.default.removeItem(at: root) } }
    }
    func load(_ urls: [URL]) {
        guard !busy else { return }
        close(); pages = []; error = nil; busy = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-sensitive-\(UUID())", isDirectory: true)
        let token = generation
        worker = Task {
            let importer = Task.detached { try SensitiveBatchIO.importPages(urls, into: root) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await importer.value }, onCancel: { importer.cancel() })
                guard !Task.isCancelled, token == generation else {
                    Task.detached { try? FileManager.default.removeItem(at: root) }; return
                }
                pages = result; ownedRoot = root; busy = false; status = L10n.text("已创建独立临时快照，请检查后逐张确认。")
            } catch {
                guard token == generation else { return }
                busy = false; self.error = error.localizedDescription
            }
        }
    }
    func scan(rules: [SensitiveRule]) {
        guard !busy, !pages.isEmpty else { return }
        busy = true; error = nil
        let snapshots = pages, token = generation
        worker = Task {
            let scanner = Task.detached { () throws -> [SensitiveBatchPage] in
                var result = snapshots
                for index in result.indices {
                    try Task.checkCancellation()
                    let image = try SensitiveBatchIO.read(result[index].snapshot)
                    let lines = try await CaptureEngine.recognizeLines(image)
                    result[index].candidates = try SensitiveRuleEvaluation.classify(lines, kinds: Set(SensitiveKind.allCases), rules: rules, scope: .images)
                    result[index].selected = Set(result[index].candidates.map(\.id))
                    result[index].scanned = true; result[index].reviewed = false
                }
                return result
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await scanner.value }, onCancel: { scanner.cancel() })
                guard !Task.isCancelled, token == generation else { return }
                pages = result; busy = false; status = L10n.text("检查完成。可取消误报、框选漏报；请逐张确认。")
            } catch {
                guard token == generation else { return }
                busy = false; self.error = error.localizedDescription
            }
        }
    }
    func export(to parent: URL) {
        guard !busy else { return }
        let snapshots = pages, token = generation
        let destination = parent.appendingPathComponent("DeskCapture-脱敏-\(UUID())", isDirectory: true)
        busy = true; error = nil
        worker = Task {
            let exporter = Task.detached { try SensitiveBatchIO.export(snapshots, to: destination) }
            do {
                try await withTaskCancellationHandler(operation: { try await exporter.value }, onCancel: { exporter.cancel() })
                guard token == generation else { return }
                busy = false; status = L10n.text("已导出\(snapshots.count)张独立PNG：\(destination.path)")
            } catch {
                guard token == generation else { return }
                busy = false; self.error = error.localizedDescription
            }
        }
    }
}
