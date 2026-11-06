import AppKit
import Vision

struct OCRTableCell: Equatable {
    var row: Int
    var column: Int
    var rowSpan: Int
    var columnSpan: Int
    var text: String
    var bounds: CGRect? = nil
}

struct OCRTableResult {
    let rows: [[String]]
    let cells: [OCRTableCell]
    let recoveredEmptyCells: Int
    let unassignedLines: [OCRLine]
    var requiresReview: Bool { hasMergedCells || !unassignedLines.isEmpty }
    var hasMergedCells: Bool { cells.contains { $0.rowSpan > 1 || $0.columnSpan > 1 } }
    var tsv: String { rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") }
    static func assemble(_ cells: [OCRTableCell], recovered: Int = 0, unassignedLines: [OCRLine] = []) throws -> OCRTableResult {
        guard !cells.isEmpty, cells.count <= 16_384 else { throw CaptureError.message(L10n.text("表格为空或超过16384个单元格，请分区识别。")) }
        var height = 0, width = 0
        for c in cells {
            guard c.row >= 0, c.column >= 0, (1...4096).contains(c.rowSpan), (1...256).contains(c.columnSpan),
                  c.row <= 4096 - c.rowSpan, c.column <= 256 - c.columnSpan else { throw CaptureError.message(L10n.text("表格行列范围不可靠，请框选较小区域复核。")) }
            height = max(height, c.row+c.rowSpan); width = max(width, c.column+c.columnSpan)
        }
        guard height * width <= 16_384, cells.reduce(0, { $0 + $1.text.utf8.count }) <= 4_000_000 else { throw CaptureError.message(L10n.text("表格过大，请分区识别。")) }
        var result = Array(repeating: Array(repeating: "", count: width), count: height)
        var occupied = Set<Int>()
        for c in cells {
            for row in c.row..<c.row+c.rowSpan { for column in c.column..<c.column+c.columnSpan {
                guard occupied.insert(row*width+column).inserted else { throw CaptureError.message(L10n.text("表格单元格范围重叠，请在原图复核。")) }
            } }
            result[c.row][c.column] = c.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        return .init(rows: result, cells: cells, recoveredEmptyCells: recovered, unassignedLines: unassignedLines)
    }
}

extension CaptureEngine {
    @available(macOS 26.0, *)
    nonisolated static func extractTable(_ image: CGImage) async throws -> OCRTableResult {
        try Task.checkCancellation()
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant"), Locale.Language(identifier: "en-US")]
        request.textRecognitionOptions.automaticallyDetectLanguage = false
        let observations = try await request.perform(on: image)
        guard let table = observations.first?.document.tables.first else { throw CaptureError.message(L10n.text("没有识别到表格。请只框选完整表格后重试。")) }
        let worker = Task.detached(priority: .userInitiated) { () throws -> OCRTableResult in
            var cells: [OCRTableCell] = [], visited = Set<String>(), retries = 0, recovered = 0
            for row in table.rows { for cell in row {
                try Task.checkCancellation()
                let key = "\(cell.rowRange)-\(cell.columnRange)"
                guard visited.insert(key).inserted else { continue }
                guard visited.count <= 16_384 else { throw CaptureError.message(L10n.text("表格过大，请分区识别。")) }
                var text = cell.content.text.transcript
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, retries < 32 {
                    retries += 1
                    let rect = cell.content.boundingRegion.boundingBox.toImageCoordinates(CGSize(width: image.width, height: image.height), origin: .upperLeft)
                    let safe = rect.insetBy(dx: 3, dy: 3).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
                    if safe.width >= 8, safe.height >= 8, safe.width * safe.height <= 4_000_000, let crop = image.cropping(to: safe) {
                        let retry = VNRecognizeTextRequest(); retry.recognitionLevel = .accurate
                        retry.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]; retry.usesLanguageCorrection = false
                        try VNImageRequestHandler(cgImage: crop).perform([retry])
                        let candidates = (retry.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }.compactMap { $0.topCandidates(1).first }
                        if !candidates.isEmpty, candidates.allSatisfy({ $0.confidence >= 0.8 && $0.string.contains(where: { $0.isLetter || $0.isNumber }) }) {
                            text = candidates.map(\.string).joined(separator: " "); recovered += 1
                        }
                    }
                }
                let pixelBounds = cell.content.boundingRegion.boundingBox.toImageCoordinates(CGSize(width: image.width, height: image.height), origin: .upperLeft)
                let normalizedBounds = CGRect(x: pixelBounds.minX / CGFloat(image.width), y: 1 - pixelBounds.maxY / CGFloat(image.height),
                                              width: pixelBounds.width / CGFloat(image.width), height: pixelBounds.height / CGFloat(image.height))
                cells.append(.init(row: cell.rowRange.lowerBound, column: cell.columnRange.lowerBound,
                                   rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count, text: text, bounds: normalizedBounds))
            } }
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: text.string, bounds: observation.boundingBox, confidence: text.confidence)
            }
            let unassigned = try OCRTableCoverage.unassigned(lines, cells: cells)
            return try OCRTableResult.assemble(cells, recovered: recovered, unassignedLines: unassigned)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

struct OCRCodeFragment {
    let text: String
    let bounds: CGRect
    let characterAdvance: CGFloat?
}
enum OCRCodeLayout {
    static func format(_ fragments: [OCRCodeFragment]) -> String {
        let ordered = fragments.filter { !$0.text.isEmpty && !$0.bounds.isEmpty }.sorted { $0.bounds.midY > $1.bounds.midY }
        guard let left = ordered.map(\.bounds.minX).min() else { return "" }
        let measured = ordered.compactMap(\.characterAdvance).filter { $0.isFinite && $0 > 0 }.sorted()
        let estimates = ordered.map { $0.bounds.width / CGFloat(max(1, $0.text.count)) }.sorted()
        let unit = max(0.00001, measured.isEmpty ? estimates[estimates.count / 2] : measured[measured.count / 2])
        var rows: [[OCRCodeFragment]] = []
        for fragment in ordered {
            if let index = rows.firstIndex(where: { row in
                guard let first = row.first else { return false }
                return abs(first.bounds.midY-fragment.bounds.midY) <= min(first.bounds.height, fragment.bounds.height)*0.45
            }) { rows[index].append(fragment) } else { rows.append([fragment]) }
        }
        return rows.map { row in
            var text = "", edge = left
            for item in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                let gap = max(0, min(160, Int(((item.bounds.minX-edge)/unit).rounded())))
                text += String(repeating: " ", count: gap) + item.text
                edge = item.bounds.maxX
            }
            return text
        }.joined(separator: "\n")
    }
    static func characterAdvance(_ candidate: VNRecognizedText) -> CGFloat? {
        let text = candidate.string, indices = Array(candidate.string.indices)
        var advances: [CGFloat] = []
        for index in 0..<max(0, min(indices.count-1, 128)) {
            let a = indices[index], b = indices[index+1]
            guard text[a].isASCII, text[b].isASCII, text[a].isLetter || text[a].isNumber,
                  text[b].isLetter || text[b].isNumber,
                  let first = try? candidate.boundingBox(for: a..<b),
                  let next = try? candidate.boundingBox(for: b..<text.index(after: b)) else { continue }
            let value = next.boundingBox.minX-first.boundingBox.minX
            if value > 0 { advances.append(value) }
        }
        advances.sort()
        return advances.count >= 3 ? advances[advances.count/2] : nil
    }
}

extension OCRCodeLayout {
    /// Tighten horizontal ink bounds only on a uniform background. Vision may
    /// include a wide blank left margin; treating that margin as code adds spaces.
    static func refineHorizontalBounds(_ bounds: CGRect, image: CGImage) -> CGRect {
        let rect = CGRect(x: bounds.minX * CGFloat(image.width), y: (1-bounds.maxY) * CGFloat(image.height),
                          width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard rect.width >= 4, rect.height >= 4, rect.width*rect.height <= 4_000_000, let crop = image.cropping(to: rect) else { return bounds }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return bounds }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = raw.bindMemory(to: UInt8.self)
            func gray(_ x: Int, _ y: Int) -> Int { let i = (y*width+x)*4; return (Int(bytes[i])+Int(bytes[i+1])+Int(bytes[i+2]))/3 }
            let corners = [gray(0,0), gray(width-1,0), gray(0,height-1), gray(width-1,height-1)]
            guard corners.max()! - corners.min()! <= 12 else { return bounds }
            let background = corners.reduce(0,+)/4
            var left = width, right = -1, count = 0
            for y in 0..<height { for x in 0..<width where abs(gray(x,y)-background) >= 40 {
                left = min(left,x); right = max(right,x); count += 1
            } }
            guard count >= 4, right >= left else { return bounds }
            return CGRect(x: (rect.minX+CGFloat(left))/CGFloat(image.width), y: bounds.minY,
                          width: CGFloat(right-left+1)/CGFloat(image.width), height: bounds.height)
        }
    }
}


/// An OCR heading outside the recognized table is evidence for human review,
/// never evidence that it belongs in an automatically invented merged cell.
enum OCRTableCoverage {
    static func unassigned(_ lines: [OCRLine], cells: [OCRTableCell]) throws -> [OCRLine] {
        guard lines.count <= 5000, lines.reduce(0, { $0 + $1.text.utf8.count }) <= 4_000_000 else { throw CaptureError.message(L10n.text("表格复核文本超预算，请缩小区域。")) }
        func bins(_ bounds: CGRect) -> ClosedRange<Int>? {
            guard !bounds.isNull, !bounds.isInfinite, bounds.height > 0, bounds.width > 0,
                  [bounds.minY, bounds.maxY, bounds.minX, bounds.maxX].allSatisfy(\.isFinite) else { return nil }
            return min(99, max(0, Int(floor(bounds.minY * 100))))...min(99, max(0, Int(floor(bounds.maxY * 100))))
        }
        var index: [Int: [Int]] = [:]
        for (number, cell) in cells.enumerated() {
            if let bounds = cell.bounds, let keys = bins(bounds) { for key in keys { index[key, default: []].append(number) } }
        }
        func compact(_ value: String) -> String { String(value.filter { !$0.isWhitespace }).lowercased() }
        var result: [OCRLine] = []
        for line in lines {
            try Task.checkCancellation()
            let needle = compact(line.text)
            guard !needle.isEmpty else { continue }
            guard let keys = bins(line.bounds) else { result.append(line); continue }
            let candidates = Set(keys.flatMap { index[$0] ?? [] }).map { cells[$0] }.filter { cell in
                guard let bounds = cell.bounds else { return false }
                let intersection = bounds.intersection(line.bounds)
                return !intersection.isEmpty && intersection.height >= min(bounds.height, line.bounds.height) * 0.25
            }.sorted { ($0.bounds?.minX ?? 0) < ($1.bounds?.minX ?? 0) }
            let known = compact(candidates.map(\.text).joined())
            if !known.contains(needle) { result.append(line) }
        }
        return result.sorted { $0.bounds.midY > $1.bounds.midY }
    }
}
