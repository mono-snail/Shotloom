import Foundation
import PDFKit

struct ClipboardPDFHighlightSnapshot {
    let pageIndex: Int
    let bounds: CGRect
    let color: CGColor
}

/// Immutable source bytes and edit values; no displayed PDFKit object crosses
/// onto the encoder's worker thread.
enum ClipboardSaveSnapshot: @unchecked Sendable {
    case text(String, xml: Bool)
    case pdf(Data, highlights: [ClipboardPDFHighlightSnapshot] = [])

    @MainActor
    static func capturePDF(sourceData: Data, document: PDFDocument,
                           highlights: [(PDFPage, PDFAnnotation)]) throws -> Self {
        let edits = try highlights.map { entry -> ClipboardPDFHighlightSnapshot in
            let (page, annotation) = entry
            let index = document.index(for: page)
            guard index >= 0, index < document.pageCount else { throw CaptureError.message(L10n.text("PDF 编辑页面已失效。")) }
            return .init(pageIndex: index, bounds: annotation.bounds, color: annotation.color.cgColor)
        }
        return .pdf(sourceData, highlights: edits)
    }
    static func extractedText(from document: PDFDocument, maximumBytes: Int = 20_000_000) throws -> String {
        guard document.allowsCopying else { throw CaptureError.message(L10n.text("这个 PDF 不允许提取文字。")) }
        var pages: [String] = [], bytes = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = document.page(at: index)?.string ?? ""
            let added = text.utf8.count + (pages.isEmpty ? 0 : 1)
            guard added <= maximumBytes - bytes else { throw CaptureError.message(L10n.text("提取文字超过20MB，未截断输出。")) }
            bytes += added; pages.append(text)
        }
        try Task.checkCancellation()
        return pages.joined(separator: "\n")
    }
    func encoded() throws -> Data {
        try Task.checkCancellation()
        let data: Data
        switch self {
        case .text(let text, let xml): data = try xml ? XMLTextFormatter.dataForSaving(text) : Data(text.utf8)
        case .pdf(let source, let highlights):
            guard let document = PDFDocument(data: source) else { throw CaptureError.message(L10n.text("PDF 无法读取保存源。")) }
            for snapshot in highlights {
                try Task.checkCancellation()
                guard let page = document.page(at: snapshot.pageIndex) else { throw CaptureError.message(L10n.text("PDF 保存页面已失效。")) }
                let annotation = PDFAnnotation(bounds: snapshot.bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor(cgColor: snapshot.color) ?? .systemYellow
                page.addAnnotation(annotation)
            }
            guard let bytes = document.dataRepresentation() else { throw CaptureError.message(L10n.text("PDF 无法导出。")) }
            data = bytes
        }
        try Task.checkCancellation()
        return data
    }
}
