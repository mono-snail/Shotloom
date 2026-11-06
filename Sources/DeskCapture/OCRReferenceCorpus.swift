import AppKit
import CoreText
import CoreImage

/// Generated reference answers. No user documents or clipboard are used.
enum OCRReferenceCorpus {
    struct Sample {
        let id: String
        let category: String
        let fontSize: CGFloat
        let lines: [String]
        var expected: String { lines.joined(separator: "\n") }
        var tableTSV: String? { category == "table" ? lines.joined(separator: "\n") : nil }
    }
    static let samples: [Sample] = [CGFloat(12), 18, 26, 34].flatMap { size in
        [Sample(id: "mixed-\(Int(size))", category: "mixed", fontSize: size,
                lines: [L10n.text("截图 Capture 2026"), L10n.text("价格 Price: 128.50"), L10n.text("本地处理 Local processing")]),
         Sample(id: "fine-\(Int(size))", category: "fine", fontSize: size,
                lines: ["Invoice ID: DC-01789", "Version 2.4.0 / build 32", "0123456789 ABC xyz"]),
         Sample(id: "code-\(Int(size))", category: "code", fontSize: size,
                lines: ["func total(_ values: [Int]) -> Int {", "    return values.reduce(0, +)", "}"]),
         Sample(id: "table-\(Int(size))", category: "table", fontSize: size,
                lines: ["Item\tCount\tPrice", "Apple\t12\t3.50", "Pear\t7\t2.80"]),
         Sample(id: "qr-\(Int(size))", category: "qr", fontSize: size,
                lines: ["https://example.invalid/deskcapture?sample=\(Int(size))&value=128.50"])]
    }
    static func render(_ sample: Sample) throws -> CGImage {
        if sample.category == "qr" {
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data(sample.expected.utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            guard let output = filter.outputImage,
                  let image = CIContext().createCGImage(output, from: output.extent) else { throw CaptureError.message("QR fixture generation failed") }
            let scale = Int(sample.fontSize) / 6
            let side = (image.width + 8) * scale
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 4 * scale, y: 4 * scale, width: image.width * scale, height: image.height * scale))
            return context.makeImage()!
        }
        let context = CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        for (index, row) in sample.lines.enumerated() {
            let columns = row.components(separatedBy: "\t")
            for (column, value) in columns.enumerated() {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName((sample.category == "code" ? "Menlo" : "PingFangSC-Regular") as CFString, sample.fontSize, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
                context.textPosition = CGPoint(x: 32 + column * 320, y: 330 - index * 90)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes)), context)
            }
        }
        if sample.category == "table" {
            context.setStrokeColor(CGColor(gray: 0.35, alpha: 1)); context.setLineWidth(1)
            for x in [20, 340, 660, 980] { context.move(to: CGPoint(x: x, y: 120)); context.addLine(to: CGPoint(x: x, y: 380)) }
            for y in [120, 210, 300, 380] { context.move(to: CGPoint(x: 20, y: y)); context.addLine(to: CGPoint(x: 980, y: y)) }
            context.strokePath()
        }
        return context.makeImage()!
    }
    static func referenceBounds(_ sample: Sample) -> [CGRect] {
        guard sample.category != "qr", sample.category != "table" else { return [] }
        return sample.lines.enumerated().map { index, value in
            let font = CTFontCreateWithName((sample.category == "code" ? "Menlo" : "PingFangSC-Regular") as CFString, sample.fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).offsetBy(dx: 32, dy: CGFloat(330 - index * 90))
        }
    }
}
