import AppKit
import CoreText

struct OCRFontFit: Codable, Equatable, Sendable {
    let fontName: String
    let sizePixels: CGFloat
    let trackingPixels: CGFloat
    let baselinePixels: CGFloat
    let originXPixels: CGFloat
    let weight: Double
    let maskError: Double
}
struct OCRFontCandidate: Identifiable {
    var id: String { fit.fontName }
    let fit: OCRFontFit
    let preview: CGImage
}
struct OCRFontFittingResult {
    let source: CGImage
    let candidates: [OCRFontCandidate]
    let fontsCompared: Int
    let availableFonts: Int
}

enum OCRFontFitting {
    private struct Mask { let width: Int; let height: Int; let left: Int; let bytes: [UInt8] }
    static func fit(image: CGImage, bounds: CGRect, text: String) async throws -> OCRFontFittingResult {
        let worker = Task.detached(priority: .userInitiated) { try compute(image: image, bounds: bounds, text: text) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func compute(image: CGImage, bounds: CGRect, text: String) throws -> OCRFontFittingResult {
        guard !text.isEmpty, text.count <= 128, !text.contains("\n"),
              [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite), !bounds.isEmpty else {
            throw CaptureError.message(L10n.text("请先校对一行文字（最多128字），再拟合字体。"))
        }
        let rect = CGRect(x: bounds.minX * CGFloat(image.width), y: (1-bounds.maxY) * CGFloat(image.height),
                          width: bounds.width * CGFloat(image.width), height: bounds.height * CGFloat(image.height))
            .insetBy(dx: -3, dy: -3).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard rect.width > 0, rect.height > 0, rect.width * rect.height <= 500_000,
              let source = image.cropping(to: rect), let target = mask(source, requireUniform: true) else {
            throw CaptureError.message(L10n.text("背景或文字边界不适合自动拟合，请手动选择字体和字号。"))
        }
        let installed = Set((CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [])
        let preferred = ["PingFangSC-Regular", "PingFangSC-Medium", "PingFangSC-Semibold", "PingFangTC-Regular",
                         "HelveticaNeue", "HelveticaNeue-Medium", "HelveticaNeue-Bold", "ArialMT", "Arial-BoldMT",
                         "Menlo-Regular", "Menlo-Bold", "Monaco", "Georgia", "Georgia-Bold", "TimesNewRomanPSMT", "CourierNewPSMT"]
        let names = Array((preferred.filter(installed.contains) + installed.subtracting(preferred).sorted()).prefix(48))
        var candidates: [OCRFontCandidate] = [], compared = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        for name in names {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime > deadline { break }
            let font = CTFontCreateWithName(name as CFString, 100, nil)
            guard CTFontCopyPostScriptName(font) as String == name, supports(text, font: font),
                  let reference = render(text, name: name, size: 100, tracking: 0), let refMask = mask(reference, requireUniform: false) else { continue }
            compared += 1
            let estimate = CGFloat(target.height) / CGFloat(refMask.height) * 100
            let sizes = Set(stride(from: max(6, estimate-2), through: min(256, estimate+2), by: 0.25).map { $0 }
                + [-1,0,1].map { max(6, min(256, estimate.rounded()+CGFloat($0))) }).sorted()
            var best: (Double, CGFloat, CGFloat, CGImage)?
            for size in sizes {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime > deadline { break }
                guard let natural = render(text, name: name, size: size, tracking: 0), let naturalMask = mask(natural, requireUniform: false) else { continue }
                let adjustment = max(-size*0.15, min(size*0.15, CGFloat(target.width-naturalMask.width)/CGFloat(max(1,text.count-1))))
                for tracking in Set([CGFloat(0), adjustment]) {
                    guard let preview = tracking == 0 ? natural : render(text, name: name, size: size, tracking: tracking),
                          let candidate = mask(preview, requireUniform: false) else { continue }
                    let error = distance(target, candidate)
                    if best == nil || error < best!.0 { best = (error,size,tracking,preview) }
                }
            }
            if let best {
                let glyphBounds = lineBounds(text, name: name, size: best.1, tracking: best.2)
                let traits = CTFontCopyTraits(font) as NSDictionary
                let fit = OCRFontFit(fontName: name, sizePixels: best.1, trackingPixels: best.2,
                    baselinePixels: bounds.minY*CGFloat(image.height)-glyphBounds.minY,
                    originXPixels: rect.minX+CGFloat(target.left)-glyphBounds.minX,
                    weight: (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0, maskError: best.0)
                candidates.append(.init(fit: fit, preview: best.3))
            }
        }
        guard !candidates.isEmpty else { throw CaptureError.message(L10n.text("已安装字体中没有适合这行文字的候选。")) }
        candidates.sort { $0.fit.maskError < $1.fit.maskError }
        return .init(source: source, candidates: Array(candidates.prefix(5)), fontsCompared: compared, availableFonts: installed.count)
    }
    private static func supports(_ text: String, font: CTFont) -> Bool {
        let chars = Array(text.utf16); var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
    }
    private static func attributed(_ text: String, name: String, size: CGFloat, tracking: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(name as CFString,size,nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0,alpha: 1), NSAttributedString.Key(kCTKernAttributeName as String): tracking])
    }
    private static func lineBounds(_ text: String, name: String, size: CGFloat, tracking: CGFloat) -> CGRect {
        CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attributed(text,name:name,size:size,tracking:tracking)), .useGlyphPathBounds)
    }
    private static func render(_ text: String, name: String, size: CGFloat, tracking: CGFloat) -> CGImage? {
        let line = CTLineCreateWithAttributedString(attributed(text,name:name,size:size,tracking:tracking))
        let bounds = CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
        let width = Int(ceil(bounds.width))+10, height = Int(ceil(bounds.height))+10
        guard width > 0, height > 0, width * height <= 2_000_000,
              let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                                     space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.textPosition = CGPoint(x:5-floor(bounds.minX),y:5-floor(bounds.minY)); CTLineDraw(line,context)
        return context.makeImage()
    }
    private static func mask(_ image: CGImage, requireUniform: Bool) -> Mask? {
        var pixels = [UInt8](repeating:255,count:image.width*image.height)
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
            context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            let bytes = raw.bindMemory(to:UInt8.self), w = image.width, h = image.height
            let corners = [Int(bytes[0]),Int(bytes[w-1]),Int(bytes[(h-1)*w]),Int(bytes[w*h-1])]
            if requireUniform && corners.max()! - corners.min()! > 16 { return nil }
            let background = corners.reduce(0,+)/4
            var contrast = 0
            for v in bytes { contrast = max(contrast,abs(Int(v)-background)) }
            guard contrast >= 48 else { return nil }
            var x0=w,y0=h,x1 = -1,y1 = -1
            for y in 0..<h { for x in 0..<w where abs(Int(bytes[y*w+x])-background)*255/contrast >= 55 {
                x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
            } }
            guard x1>=x0,y1>=y0 else { return nil }
            let width=x1-x0+1,height=y1-y0+1; var result=[UInt8](repeating:255,count:width*height)
            for y in 0..<height { for x in 0..<width { result[y*width+x]=UInt8(255-min(255,abs(Int(bytes[(y+y0)*w+x+x0])-background)*255/contrast)) } }
            return .init(width:width,height:height,left:x0,bytes:result)
        }
    }
    private static func distance(_ a: Mask, _ b: Mask) -> Double {
        let width=max(a.width,b.width),height=max(a.height,b.height); var error:Double=0
        for y in 0..<height { for x in 0..<width {
            let av = x<a.width && y<a.height ? a.bytes[y*a.width+x] : 255
            let bv = x<b.width && y<b.height ? b.bytes[y*b.width+x] : 255
            error += Double(abs(Int(av)-Int(bv)))
        } }
        return error/Double(width*height*255)
    }
}
