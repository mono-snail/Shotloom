import AppKit

enum ScrollImageCapacity {
    static func canRenderWhole(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, max(width, height) <= 60_000 else { return false }
        return width <= 80_000_000 / height
    }
}

struct ScrollRenderPiece {
    let url: URL
    let crop: CGRect
    let destination: CGRect // Original pixels, top-left origin.
}

struct ScrollExportPlan {
    let width: Int
    let height: Int
    let axis: ScrollAxis
    let pieces: [ScrollRenderPiece]
    var canRenderWhole: Bool { ScrollImageCapacity.canRenderWhole(width: width, height: height) }

    func render(_ region: CGRect) throws -> CGImage {
        try Task.checkCancellation()
        guard region.width > 0, region.height > 0, region.width * region.height <= 16_777_216,
              let context = CGContext(data: nil, width: Int(region.width), height: Int(region.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("分块尺寸超过内存预算。"))
        }
        for piece in pieces where piece.destination.intersects(region) {
            try Task.checkCancellation()
            try autoreleasepool {
                let overlap = piece.destination.intersection(region)
                let crop = CGRect(x: piece.crop.minX + overlap.minX - piece.destination.minX,
                                  y: piece.crop.minY + overlap.minY - piece.destination.minY, width: overlap.width, height: overlap.height)
                guard let source = CGImageSourceCreateWithURL(piece.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let part = image.cropping(to: crop) else {
                    throw CaptureError.message(L10n.text("长图片段无法读取，已保留原结果。"))
                }
                context.draw(part, in: CGRect(x: overlap.minX - region.minX, y: region.maxY - overlap.maxY,
                                             width: overlap.width, height: overlap.height))
            }
        }
        guard let image = context.makeImage() else { throw CaptureError.message(L10n.text("分块渲染失败。")) }
        return image
    }
    func regions(edge: Int = 4096) throws -> [CGRect] {
        guard width > 0, height > 0, edge > 0, edge <= 4096 else { throw CaptureError.message(L10n.text("无效分块范围。")) }
        var result: [CGRect] = []
        // Both axes are bounded, including an unusually wide capture viewport.
        for y in stride(from: 0, to: height, by: edge) {
            for x in stride(from: 0, to: width, by: edge) {
                result.append(CGRect(x: x, y: y, width: min(edge, width - x), height: min(edge, height - y)))
            }
        }
        return result
    }
    func exportSegments(to destination: URL, edge: Int = 4096, beforePart: ((Int) throws -> Void)? = nil) throws {
        let parent = destination.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".DeskCapture-parts-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let rectangles = try regions(edge: edge)
        var entries: [[String: Any]] = []
        for (index, rect) in rectangles.enumerated() {
            try Task.checkCancellation(); try beforePart?(index)
            let name = String(format: "part-%05d.png", index + 1)
            try autoreleasepool { try CaptureImageExport.png(render(rect), to: stage.appendingPathComponent(name)) }
            entries.append(["file": name, "x": Int(rect.minX), "y": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)])
        }
        let metadata: [String: Any] = ["schemaVersion": 1, "width": width, "height": height,
                                      "axis": axis == .vertical ? "vertical" : "horizontal", "parts": entries]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted]).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw CaptureError.message(L10n.text("分块目标不是文件夹，原文件已保留。")) }
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage)
        } else { try FileManager.default.moveItem(at: stage, to: destination) }
    }
    func exportPDF(to destination: URL, beforePage: ((Int) throws -> Void)? = nil) throws {
        if FileManager.default.fileExists(atPath: destination.path),
           (try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            throw CaptureError.message(L10n.text("PDF 目标是文件夹，原内容已保留。"))
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".DeskCapture-pages-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: stage) }
        var media = axis == .vertical ? CGRect(x: 0, y: 0, width: 595, height: 842) : CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let consumer = CGDataConsumer(url: stage as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw CaptureError.message(L10n.text("无法创建分页 PDF。")) }
        let cross = axis == .vertical ? width : height
        let scale = (axis == .vertical ? media.width : media.height) / CGFloat(cross)
        let primaryPage = max(1, Int(floor((axis == .vertical ? media.height : media.width) / scale)))
        let primary = axis == .vertical ? height : width
        for (page, start) in stride(from: 0, to: primary, by: primaryPage).enumerated() {
            try Task.checkCancellation(); try beforePage?(page)
            pdf.beginPDFPage(nil)
            let length = min(primaryPage, primary - start)
            let pageRect = axis == .vertical ? CGRect(x: 0, y: start, width: width, height: length) : CGRect(x: start, y: 0, width: length, height: height)
            // Draw bounded strips into the PDF; never create the whole page bitmap.
            for rect in try regionsFor(pageRect) {
                try autoreleasepool {
                    let image = try render(rect)
                    let x = (rect.minX - pageRect.minX) * scale
                    let y = media.height - (rect.maxY - pageRect.minY) * scale
                    pdf.draw(image, in: CGRect(x: x, y: y, width: rect.width * scale, height: rect.height * scale))
                }
            }
            pdf.endPDFPage()
        }
        pdf.closePDF(); try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: destination) }
    }
    private func regionsFor(_ area: CGRect) throws -> [CGRect] {
        var result: [CGRect] = []
        for y in stride(from: Int(area.minY), to: Int(area.maxY), by: 4096) {
            for x in stride(from: Int(area.minX), to: Int(area.maxX), by: 4096) {
                result.append(CGRect(x: x, y: y, width: min(4096, Int(area.maxX) - x), height: min(4096, Int(area.maxY) - y)))
            }
        }
        return result
    }
}
