import AppKit
import Vision
import ImageIO
import CoreText

struct SimplifiedBlock: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case text, control }
    var id = UUID()
    var kind: Kind
    var bounds: CGRect
    var sourceBounds: CGRect? = nil
    var parent: UUID?
    var label = ""
    var restored = false
    var darkStyle = false
}
struct SimplifiedLayout: Codable {
    var version = 1
    let sourcePNG: Data
    let blocks: [SimplifiedBlock]
}
enum UISimplification {
    static func editing(_ blocks: [SimplifiedBlock], id: UUID, change: (inout SimplifiedBlock) -> Void) throws -> [SimplifiedBlock] {
        try validate(blocks)
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return blocks }
        var draft = blocks
        let previous = blocks[index].bounds
        change(&draft[index])
        try validate(draft)
        let updated = draft[index].bounds
        if blocks[index].kind == .control, previous != updated {
            let indexed = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
            for child in draft.indices where child != index {
                var parent = blocks[child].parent, isDescendant = false
                while let ancestor = parent {
                    if ancestor == id { isDescendant = true; break }
                    parent = indexed[ancestor]?.parent
                }
                guard isDescendant else { continue }
                let box = blocks[child].bounds
                draft[child].bounds = CGRect(x: updated.minX + (box.minX - previous.minX) * updated.width / previous.width,
                                             y: updated.minY + (box.minY - previous.minY) * updated.height / previous.height,
                                             width: box.width * updated.width / previous.width,
                                             height: box.height * updated.height / previous.height)
            }
        }
        try validate(draft); return draft
    }
    static func validate(_ blocks: [SimplifiedBlock]) throws {
        guard blocks.count <= 1024, Set(blocks.map(\.id)).count == blocks.count else { throw CaptureError.message(L10n.text("布局最多1024个对象，标识不可重复。")) }
        let indexed = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        for block in blocks {
            let box = block.bounds
            guard !box.isNull, !box.isInfinite, box.minX >= 0, box.minY >= 0, box.maxX <= 1.000001, box.maxY <= 1.000001,
                  box.width > 0, box.height > 0, [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite),
                  block.label.count <= 256 else { throw CaptureError.message(L10n.text("对象需位于画布内且文字不超过256字。")) }
            if let origin = block.sourceBounds {
                guard !origin.isNull, !origin.isInfinite, origin.width > 0, origin.height > 0,
                      [origin.minX, origin.minY, origin.maxX, origin.maxY].allSatisfy(\.isFinite),
                      CGRect(x: 0, y: 0, width: 1.000001, height: 1.000001).contains(origin) else { throw CaptureError.message(L10n.text("原位置无效。")) }
            }
            var seen = Set([block.id]), parent = block.parent
            while let id = parent {
                guard let ancestor = indexed[id], seen.insert(id).inserted else { throw CaptureError.message(L10n.text("布局层级无效或存在循环。")) }
                parent = ancestor.parent
            }
        }
    }
    static func inferred(text: [CGRect], controls: [CGRect]) throws -> [SimplifiedBlock] {
        let canvas = CGRect(x: 0, y: 0, width: 1, height: 1)
        var blocks = controls.prefix(60).compactMap { box -> SimplifiedBlock? in
            let bounded = canvas.contains(box) ? box : box.intersection(canvas)
            return bounded.isEmpty ? nil : .init(kind: .control, bounds: bounded, sourceBounds: bounded)
        }
        blocks += text.prefix(900).compactMap { box -> SimplifiedBlock? in
            let bounded = canvas.contains(box) ? box : box.intersection(canvas)
            return bounded.isEmpty ? nil : .init(kind: .text, bounds: bounded, sourceBounds: bounded)
        }
        let snapshot = blocks
        for index in blocks.indices {
            let box = blocks[index].bounds, area = box.width * box.height
            blocks[index].parent = snapshot.filter { $0.id != blocks[index].id && $0.kind == .control && $0.bounds.contains(box) && $0.bounds.width * $0.bounds.height > area * 1.01 }
                .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.id
        }
        try validate(blocks); return blocks
    }
    static func detect(_ image: CGImage) async throws -> [SimplifiedBlock] {
        let worker = Task.detached(priority: .userInitiated) {
            guard image.width * image.height <= 32_000_000 else { throw CaptureError.message(L10n.text("请将图片缩小到3200万像素以内。")) }
            let rectangles = VNDetectRectanglesRequest()
            rectangles.minimumConfidence = 0.65; rectangles.maximumObservations = 60
            rectangles.minimumSize = 0.025; rectangles.minimumAspectRatio = 0.08; rectangles.maximumAspectRatio = 1
            try VNImageRequestHandler(cgImage: image).perform([rectangles])
            try Task.checkCancellation()
            let lines = try await CaptureEngine.recognizeLines(image)
            try Task.checkCancellation()
            return try inferred(text: lines.map(\.bounds), controls: rectangles.results?.map(\.boundingBox) ?? [])
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func render(source: CGImage, blocks: [SimplifiedBlock]) throws -> CGImage {
        try validate(blocks)
        let base = try SensitiveBatchIO.flattened(source, bounds: [])
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CaptureError.message(L10n.text("简化图渲染失败。")) }
        let canvas = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: canvas)
        func rect(_ block: SimplifiedBlock) -> CGRect {
            .init(x: block.bounds.minX * canvas.width, y: block.bounds.minY * canvas.height,
                  width: block.bounds.width * canvas.width, height: block.bounds.height * canvas.height)
        }
        let sorted = blocks.sorted { a, b in
            if a.kind != b.kind { return a.kind == .control }
            return a.bounds.width * a.bounds.height > b.bounds.width * b.bounds.height
        }
        // Remember original positions separately so moving a placeholder doesn't
        // uncover the original text underneath its old position.
        for block in sorted where !block.restored {
            var origin = block; origin.bounds = block.sourceBounds ?? block.bounds
            context.setFillColor(NSColor(white: block.darkStyle ? 0.16 : 0.94, alpha: 1).cgColor)
            context.fill(rect(origin).integral)
        }
        for block in sorted where !block.restored {
            try Task.checkCancellation()
            let box = rect(block), radius = min(6, box.height / 4)
            let tone: CGFloat = block.darkStyle ? (block.kind == .control ? 0.16 : 0.38) : (block.kind == .control ? 0.94 : 0.76)
            context.setFillColor(NSColor(white: tone, alpha: 1).cgColor)
            // Cover the whole OCR box before drawing the inset placeholder.
            context.fill(box.integral)
            if block.kind == .control {
                context.setStrokeColor(NSColor(white: 0.66, alpha: 1).cgColor); context.setLineWidth(1)
                context.addPath(CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)); context.strokePath()
            }
            if !block.label.isEmpty {
                let font = NSFont.systemFont(ofSize: min(28, max(6, box.height * 0.65)), weight: .medium)
                let text = NSAttributedString(string: block.label, attributes: [.font: font, .foregroundColor: NSColor(white: block.darkStyle ? 0.95 : 0.15, alpha: 1)])
                context.saveGState(); context.clip(to: box); context.textMatrix = .identity
                context.textPosition = CGPoint(x: box.minX + 3, y: box.minY + max(1, (box.height - font.ascender - font.descender) / 2))
                CTLineDraw(CTLineCreateWithAttributedString(text), context); context.restoreGState()
            }
        }
        for block in blocks where block.restored {
            context.saveGState(); context.clip(to: rect(block)); context.draw(base, in: canvas); context.restoreGState()
        }
        guard let image = context.makeImage() else { throw CaptureError.message(L10n.text("简化图渲染失败。")) }; return image
    }
    static func project(source: CGImage, blocks: [SimplifiedBlock]) throws -> Data {
        try validate(blocks)
        let pixels = try SensitiveBatchIO.flattened(source, bounds: [])
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CaptureError.message(L10n.text("原图编码失败。")) }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 64_000_000 else { throw CaptureError.message(L10n.text("工程原图超过64MB或编码失败。")) }
        let result = try JSONEncoder().encode(SimplifiedLayout(sourcePNG: data as Data, blocks: blocks))
        guard result.count <= 90_000_000 else { throw CaptureError.message(L10n.text("工程超过90MB。")) }; return result
    }
    static func open(_ data: Data) throws -> (CGImage, [SimplifiedBlock]) {
        guard data.count <= 90_000_000 else { throw CaptureError.message(L10n.text("工程超过90MB。")) }
        let layout = try JSONDecoder().decode(SimplifiedLayout.self, from: data)
        guard layout.version == 1, layout.sourcePNG.count <= 64_000_000,
              let source = CGImageSourceCreateWithData(layout.sourcePNG as CFData, nil), CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 16_000, h <= 16_000, w * h <= 32_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.message(L10n.text("工程版本或原图无效。")) }
        try validate(layout.blocks); return (image, layout.blocks)
    }
}
