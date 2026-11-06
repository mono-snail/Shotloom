import AppKit
import CoreText

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let kinds = ["plain-text", "mixed-Chinese-English", "table", "graphics", "long-paragraph"]
var entries: [[String: Any]] = []
func text(_ id: String, kind: String, row: Int) -> String {
    let marker = String(format: "%@ ROW%04d", id, row)
    switch kind {
    case "mixed-Chinese-English": return "\(marker) 中文内容校验 English punctuation: αβ 0123456789。"
    case "table": return "\(marker)\tA-\(row * 17)\tB-\(row * 31)\tC-\(row % 7)"
    case "graphics": return "\(marker) Generated graphic \(row), independent local content."
    case "long-paragraph": return "\(marker) This paragraph wraps naturally in the real document view. Its unique number identifies ordering and completeness across overlapping frames. 第\(row)段仅为本机测试生成。"
    default: return "\(marker) Generated local document line \(row): sample \(row * 7919)."
    }
}
func graphic(_ seed: Int) -> CGImage {
    let context = CGContext(data: nil, width: 420, height: 70, bitsPerComponent: 8, bytesPerRow: 420 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 420, height: 70))
    for column in 0..<42 {
        let color = NSColor(calibratedRed: CGFloat((column * 37 + seed * 13) % 255) / 255,
                green: CGFloat((column * 19 + seed * 41) % 255) / 255,
                blue: CGFloat((column * 71 + seed * 7) % 255) / 255, alpha: 1).usingColorSpace(.sRGB)!.cgColor
        context.setFillColor(color)
        context.fill(CGRect(x: column * 10, y: 8, width: 8, height: 50))
    }
    return context.makeImage()!
}
for index in 0..<20 {
    try autoreleasepool {
        let id = String(format: "T%03d", index + 1), kind = kinds[index / 4], variant = index % 4
        let font = NSFont(name: "Menlo", size: CGFloat(14 + variant))!
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 240), NSTextTab(textAlignment: .left, location: 330), NSTextTab(textAlignment: .left, location: 420)]
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
        let content = NSMutableAttributedString(string: "DeskCapture Fixture \(id) - \(kind)\n", attributes: attributes)
        var rows: [[String: Any]] = []
        for row in 1...90 {
            let start = content.length, value = text(id, kind: kind, row: row)
            content.append(NSAttributedString(string: value + "\n", attributes: attributes))
            rows.append(["row": row, "utf16Start": start, "utf16Length": (value as NSString).length, "marker": String(format: "%@ ROW%04d", id, row)])
            if kind == "graphics", row % 6 == 0 {
                let data = NSBitmapImageRep(cgImage: graphic(row + variant)).representation(using: .png, properties: [:])!
                let imageFile = FileWrapper(regularFileWithContents: data); imageFile.preferredFilename = "graph-\(row).png"
                let attachment = NSTextAttachment(fileWrapper: imageFile)
                content.append(NSAttributedString(attachment: attachment)); content.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        let file = root.appendingPathComponent("DeskCapture-Fixture-\(id).rtfd", isDirectory: true)
        let wrapper = try content.fileWrapper(from: NSRange(location: 0, length: content.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd, .paperSize: NSSize(width: 640, height: 900), .backgroundColor: NSColor.white])
        try wrapper.write(to: file, options: .atomic, originalContentsURL: nil)
        let reread = try NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        guard reread.string == content.string else { fatalError("RTFD text changed during write") }
        var attachments = 0
        reread.enumerateAttribute(.attachment, in: NSRange(location: 0, length: reread.length)) { value, _, _ in if value != nil { attachments += 1 } }
        guard attachments == (kind == "graphics" ? 15 : 0) else { fatalError("RTFD graphics missing") }
        try JSONSerialization.data(withJSONObject: ["id": id, "kind": kind, "variant": variant, "rows": rows], options: [.prettyPrinted]).write(to: root.appendingPathComponent("\(id)-rows.json"), options: .atomic)
        entries.append(["id": id, "file": file.path, "kind": kind, "variant": variant, "direction": index % 2 == 0 ? "forward" : "reverse", "rows": 90])
    }
}
for index in 0..<20 {
    try autoreleasepool {
        let id = String(format: "P%03d", index + 1), kind = kinds[index / 4], variant = index % 4
        let file = root.appendingPathComponent("DeskCapture-Fixture-\(id).pdf")
        var media = CGRect(x: 0, y: 0, width: 640, height: 900)
        let consumer = CGDataConsumer(url: file as CFURL)!
        let context = CGContext(consumer: consumer, mediaBox: &media, nil)!
        let rowsPerPage = kind == "long-paragraph" ? 12 : kind == "graphics" ? 21 : kind == "mixed-Chinese-English" ? 16 : 25
        let rowHeight = kind == "long-paragraph" ? 64 : kind == "mixed-Chinese-English" ? 48 : 32
        for page in 0..<6 {
            context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(media)
            let heading = CTLineCreateWithAttributedString(NSAttributedString(string: "DeskCapture Fixture \(id) - \(kind) - Page \(page + 1)/6", attributes: [.font: CTFontCreateWithName("Menlo" as CFString, 10, nil)]))
            context.textPosition = CGPoint(x: 20, y: 880); CTLineDraw(heading, context)
            for line in 0..<rowsPerPage {
                let value = text(id, kind: kind, row: page * rowsPerPage + line + 1)
                let font = CTFontCreateWithName("Menlo" as CFString, CGFloat(12 + variant), nil)
                let style = NSMutableParagraphStyle()
                style.tabStops = [NSTextTab(textAlignment: .left, location: 240), NSTextTab(textAlignment: .left, location: 330), NSTextTab(textAlignment: .left, location: 420)]
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]
                let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
                let path = CGPath(rect: CGRect(x: 20, y: 860 - (line + 1) * rowHeight, width: 600, height: rowHeight - 4), transform: nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
                guard CTFrameGetVisibleStringRange(frame).length == (value as NSString).length else { fatalError("PDF row clipped: \(id) \(line)") }
                CTFrameDraw(frame, context)
            }
            if kind == "graphics" {
                context.draw(graphic(page + variant), in: CGRect(x: 60, y: 40, width: 420, height: 70))
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard CGPDFDocument(file as CFURL)?.numberOfPages == 6 else { fatalError("PDF readback failed") }
        entries.append(["id": id, "file": file.path, "kind": kind, "variant": variant, "direction": index % 2 == 0 ? "forward" : "reverse", "pages": 6, "rowsPerPage": rowsPerPage])
    }
}
try JSONSerialization.data(withJSONObject: ["generatedInputsOnly": true, "entries": entries], options: [.prettyPrinted]).write(to: root.appendingPathComponent("native-inputs.json"), options: .atomic)
print("Generated \(entries.count) independent local documents in \(root.path)")
