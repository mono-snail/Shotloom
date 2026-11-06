import AppKit
import CoreText
import Vision

/// A bounded raster fallback for code punctuation. Letters/digits compete in the
/// matcher but are never inserted. No grammar, dictionaries or balanced-brace rules.
enum OCRCodeGlyphs {
    struct Match: Sendable { let text: String; let error: Double; let margin: Double }
    private struct Ink: Sendable { let width: Int; let height: Int; let bytes: [UInt8] }
    private struct Template: Sendable { let text: String; let font: String; let ink: Ink }
    private struct Plane {
        let width: Int; let height: Int; let bytes: [UInt8]; let background: Int
        func ink(in rect: CGRect) -> Ink? {
            let r = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            guard !r.isEmpty, r.width * r.height <= 32_768 else { return nil }
            var x0 = Int(r.maxX), y0 = Int(r.maxY), x1 = -1, y1 = -1
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) where abs(Int(bytes[y*width+x])-background) > 40 {
                x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y)
            } }
            guard x1 >= x0, y1 >= y0 else { return nil }
            var values: [UInt8] = []
            for y in y0...y1 { for x in x0...x1 { values.append(UInt8(abs(Int(bytes[y*width+x])-background))) } }
            return .init(width: x1-x0+1, height: y1-y0+1, bytes: values)
        }
    }
    private static let symbols = (33...126).map { String(UnicodeScalar($0)!) }
        + ["->", "=>", "<=", ">=", "==", "!=", "++", "--", "<<", ">>", "&&", "||", "::", "+=", "-=", "**", "→", "≥", "≤"]
    private static let templates: [Template] = {
        ["Menlo-Regular", "Menlo-Bold", "Monaco", "CourierNewPSMT"].flatMap { font in
            symbols.compactMap { text -> Template? in
                guard let image = render(text, font: font, size: 100, phase: 0),
                      let plane = plane(image), let ink = plane.ink(in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { return nil }
                return Template(text: text, font: font, ink: ink)
            }
        }
    }()

    static func recover(_ observations: [VNRecognizedTextObservation], image: CGImage) throws -> [OCRCodeFragment] {
        try Task.checkCancellation()
        var fragments: [OCRCodeFragment] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let pixels = plane(image)
        var requests = 0
        func fit(_ rect: CGRect) throws -> Match? {
            try Task.checkCancellation()
            guard requests < 16, ProcessInfo.processInfo.systemUptime < deadline, let ink = pixels?.ink(in: rect) else { return nil }
            requests += 1
            return try match(ink, deadline: deadline)
        }
        for observation in observations {
            try Task.checkCancellation()
            guard let candidate = observation.topCandidates(1).first else { continue }
            let original = candidate.string
            var text = ""
            for index in original.indices {
                try Task.checkCancellation()
                let current = String(original[index])
                if "><=+-:|&!→≥≤".contains(original[index]),
                   let box = try? candidate.boundingBox(for: index..<original.index(after: index)),
                   let recovered = try fit(pixelRect(box.boundingBox, image: image).insetBy(dx: -1, dy: -1)),
                   recovered.text != current {
                    text += recovered.text
                } else { text += current }
            }
            fragments.append(.init(text: text, bounds: OCRCodeLayout.refineHorizontalBounds(observation.boundingBox, image: image),
                                   characterAdvance: OCRCodeLayout.characterAdvance(candidate)))
        }
        guard let pixels, !fragments.isEmpty, observations.count <= 500 else { return fragments }
        let heights = fragments.map { $0.bounds.height * CGFloat(image.height) }.sorted()
        let typicalHeight = heights[heights.count/2]
        guard typicalHeight >= 6, typicalHeight <= 128 else { return fragments }
        // Only wholly unrecognized ink rows are eligible; never splice pieces of
        // existing rows or interpret an unmatched letter as missing punctuation.
        var rows: [CGRect] = [], first: Int?, left = pixels.width, right = -1, last = 0
        for y in 0..<pixels.height {
            if y % 64 == 0 {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime >= deadline { return fragments }
            }
            var x0 = pixels.width, x1 = -1
            for x in 0..<pixels.width where abs(Int(pixels.bytes[y*pixels.width+x])-pixels.background) > 40 { x0 = min(x0,x); x1 = max(x1,x) }
            if x1 >= x0 {
                if first == nil { first = y }
                left = min(left,x0); right = max(right,x1); last = y
            } else if let start = first, y-last > 1 {
                rows.append(CGRect(x: left, y: start, width: right-left+1, height: last-start+1))
                first = nil; left = pixels.width; right = -1
                if rows.count > 500 { return fragments }
            }
        }
        if let start = first { rows.append(CGRect(x: left, y: start, width: right-left+1, height: last-start+1)) }
        for row in rows {
            guard row.height >= typicalHeight*0.55, row.height <= typicalHeight*1.8, row.width <= typicalHeight*3,
                  !observations.contains(where: { pixelRect($0.boundingBox, image: image).insetBy(dx: -2, dy: -2).intersects(row) }),
                  let recovered = try fit(row.insetBy(dx: -2, dy: -2)) else { continue }
            let bounds = CGRect(x: row.minX/CGFloat(image.width), y: 1-row.maxY/CGFloat(image.height),
                                width: row.width/CGFloat(image.width), height: row.height/CGFloat(image.height))
            fragments.append(.init(text: recovered.text, bounds: bounds, characterAdvance: nil))
        }
        return fragments
    }

    /// Exposed internally for generated-image negative/held-out cases.
    static func classify(_ image: CGImage) throws -> Match? {
        try Task.checkCancellation()
        guard let pixels = plane(image), let ink = pixels.ink(in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { return nil }
        return try match(ink, deadline: ProcessInfo.processInfo.systemUptime+2)
    }
    private static func match(_ ink: Ink, deadline: TimeInterval) throws -> Match? {
        try Task.checkCancellation()
        guard (2...128).contains(ink.width), (4...128).contains(ink.height) else { return nil }
        let shortlist = templates.map { ($0, coarse(ink,$0.ink)) }.filter { $0.1 < 0.8 }.sorted { $0.1 < $1.1 }.prefix(32)
        var scores: [String: Double] = [:]
        for (template, _) in shortlist {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let estimate = CGFloat(ink.height)/CGFloat(template.ink.height)*100
            for offset in stride(from: -1.5, through: 1.5, by: 0.5) { for phase in [CGFloat(0),0.5] {
                guard let image = render(template.text, font: template.font, size: max(5,estimate+offset), phase: phase),
                      let plane = plane(image), let candidate = plane.ink(in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { continue }
                let error = distance(ink,candidate)
                scores[template.text] = min(scores[template.text] ?? 1, error)
            } }
        }
        let ordered = scores.sorted { $0.value < $1.value }
        guard ordered.count >= 2, let best = ordered.first, best.value <= 0.18,
              !best.key.contains(where: { $0.isLetter || $0.isNumber }), ordered[1].value-best.value >= 0.15 else { return nil }
        return .init(text: best.key, error: best.value, margin: ordered[1].value-best.value)
    }
    private static func coarse(_ a: Ink, _ b: Ink) -> Double {
        let ratio = abs(log((Double(a.width)/Double(a.height))/(Double(b.width)/Double(b.height))))
        guard ratio < 0.4 else { return 1 }
        var overlap = 0, union = 0
        for y in 0..<32 { for x in 0..<32 {
            let av = a.bytes[(y*a.height/32)*a.width+x*a.width/32] >= 100
            let bv = b.bytes[(y*b.height/32)*b.width+x*b.width/32] >= 100
            if av || bv { union += 1 }; if av && bv { overlap += 1 }
        } }
        return 1-Double(overlap)/Double(max(1,union))+ratio*0.3
    }
    private static func distance(_ a: Ink, _ b: Ink) -> Double {
        guard abs(a.width-b.width) <= 2, abs(a.height-b.height) <= 2 else { return 1 }
        var best = 1.0
        for dy in -1...1 { for dx in -1...1 {
            var error = 0, weight = 0
            for y in -2..<(max(a.height,b.height)+2) { for x in -2..<(max(a.width,b.width)+2) {
                let av = x >= 0 && y >= 0 && x < a.width && y < a.height ? Int(a.bytes[y*a.width+x]) : 0
                let bx = x-dx, by = y-dy
                let bv = bx >= 0 && by >= 0 && bx < b.width && by < b.height ? Int(b.bytes[by*b.width+bx]) : 0
                error += abs(av-bv); weight += max(av,bv)
            } }
            best = min(best,Double(error)/Double(max(1,weight)))
        } }
        return best
    }
    private static func pixelRect(_ bounds: CGRect, image: CGImage) -> CGRect {
        CGRect(x: bounds.minX*CGFloat(image.width), y: (1-bounds.maxY)*CGFloat(image.height),
               width: bounds.width*CGFloat(image.width), height: bounds.height*CGFloat(image.height))
    }
    private static func plane(_ image: CGImage) -> Plane? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 16_384, h <= 16_384, w*h <= 16_000_000 else { return nil }
        var bytes = [UInt8](repeating: 255, count: w*h)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard rendered else { return nil }
        let corners = [Int(bytes[0]),Int(bytes[w-1]),Int(bytes[(h-1)*w]),Int(bytes[w*h-1])]
        guard corners.max()! - corners.min()! <= 12 else { return nil }
        return Plane(width: w, height: h, bytes: bytes, background: corners.reduce(0,+)/4)
    }
    private static func render(_ text: String, font: String, size: CGFloat, phase: CGFloat) -> CGImage? {
        let face = CTFontCreateWithName(font as CFString,size,nil)
        guard CTFontCopyPostScriptName(face) as String == font else { return nil }
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(face,characters,&glyphs,characters.count) else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        let bounds = CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
        let w = Int(ceil(bounds.width))+12, h = Int(ceil(bounds.height))+12
        guard w > 0, h > 0, w*h <= 32_768,
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.textPosition = CGPoint(x: 5-floor(bounds.minX)+phase,y: 5-floor(bounds.minY)); CTLineDraw(line,c)
        return c.makeImage()
    }
}
