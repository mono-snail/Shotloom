import AppKit
import CoreText

enum TutorialExporter {
    static func export(_ steps: [TutorialStep], directory: URL, to output: URL) throws {
        try TutorialEditing.validate(steps)
        for frame in steps.flatMap(TutorialEditing.frames) { try Task.checkCancellation(); try TutorialEditing.validateImage(directory.appendingPathComponent(frame.file)) }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-tutorial-\(UUID()).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: stage) }
        if output.pathExtension.lowercased() == "html" { try html(steps, directory: directory, output: stage) }
        else { try pdf(steps, directory: directory, output: stage) }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: output) }
    }
    private static func html(_ steps: [TutorialStep], directory: URL, output: URL) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CaptureError.message(L10n.text("无法创建教程HTML暂存。")) }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        var bytes = 0
        func write(_ text: String) throws { let data = Data(text.utf8); bytes += data.count; guard bytes <= 1_500_000_000 else { throw CaptureError.message(L10n.text("HTML超过1.5GB预算。")) }; try handle.write(contentsOf: data) }
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        try write(L10n.text("<!doctype html><meta charset='utf-8'><meta name='viewport' content='width=device-width'><title>操作教程</title><style>body{font:16px -apple-system,sans-serif;max-width:1000px;margin:40px auto;padding:0 24px;color:#183041}section{margin-bottom:48px}p{white-space:pre-wrap}figure{position:relative;margin:12px 0}img{width:100%;height:auto}b{position:absolute;transform:translate(-50%,-50%);background:#d83c46;color:white;border:2px solid white;border-radius:20px;padding:4px 8px}</style><h1>操作教程</h1>"))
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation(); try write("<section><h2>\(index + 1). \(escape(step.title))</h2><p>\(escape(step.detail))</p>")
            for (part, frame) in TutorialEditing.frames(step).enumerated() {
                try Task.checkCancellation()
                if step.parts != nil { try write("<h3>\(index + 1).\(part + 1) \(escape(frame.title))</h3><p>\(escape(frame.detail))</p>") }
                let data = try Data(contentsOf: directory.appendingPathComponent(frame.file))
                try write("<figure><img src='data:image/png;base64,\(data.base64EncodedString())'><b style='left:\(frame.clickX * 100)%;top:\((1 - frame.clickY) * 100)%'>\(index + 1)\(step.parts == nil ? "" : ".\(part + 1)")</b></figure>")
            }
            try write("</section>")
        }
        try handle.synchronize()
    }
    private static func pdf(_ steps: [TutorialStep], directory: URL, output: URL) throws {
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(output as CFURL, mediaBox: &media, nil) else { throw CaptureError.message(L10n.text("无法创建教程PDF。")) }
        defer { context.closePDF() }
        var pages = 0
        for (index, step) in steps.enumerated() {
            for (part, frame) in TutorialEditing.frames(step).enumerated() {
                try Task.checkCancellation()
                let prefix = "\(index + 1)" + (step.parts == nil ? "" : ".\(part + 1)")
                let notes = step.parts == nil ? frame.detail : [step.detail, frame.detail].filter { !$0.isEmpty }.joined(separator: "\n")
                let text = NSMutableAttributedString(string: L10n.text("\(prefix). \(step.parts == nil ? frame.title : step.title + L10n.text(" · ") + frame.title)\n\n") + notes,
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
                let setter = CTFramesetterCreateWithAttributedString(text)
                var offset = 0, first = true
                repeat {
                    try Task.checkCancellation(); pages += 1; guard pages <= 1000 else { throw CaptureError.message(L10n.text("教程PDF超过1000页，未导出。")) }
                    context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(media)
                    var textRect = CGRect(x: 40, y: 60, width: 515, height: 720)
                    if first {
                        let image = try CaptureImageRead.load(directory.appendingPathComponent(frame.file))
                        let scale = min(515 / CGFloat(image.width), 430 / CGFloat(image.height))
                        let box = CGRect(x: 40, y: 780 - CGFloat(image.height) * scale, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                        context.draw(image, in: box)
                        let x = box.minX + box.width * frame.clickX, y = box.minY + box.height * frame.clickY
                        context.setFillColor(NSColor.systemRed.cgColor); context.fillEllipse(in: CGRect(x: x - 12, y: y - 12, width: 24, height: 24))
                        let label = CTLineCreateWithAttributedString(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]))
                        context.textPosition = CGPoint(x: x - CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil)) / 2, y: y - 3); CTLineDraw(label, context)
                        textRect.size.height = max(200, box.minY - 80)
                    }
                    let path = CGPath(rect: textRect, transform: nil), drawn = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
                    CTFrameDraw(drawn, context); let count = CTFrameGetVisibleStringRange(drawn).length
                    guard count > 0 else { throw CaptureError.message(L10n.text("教程文字无法分页，未导出。")) }
                    offset += count; context.endPDFPage(); first = false
                } while offset < text.length
            }
        }
    }
}
