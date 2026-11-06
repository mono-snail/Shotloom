import XCTest
import AppKit
import CoreText
@testable import DeskCapture

final class OCRCodeGlyphTests: XCTestCase {
    private func glyph(_ text: String, font: String, size: CGFloat, dark: Bool = false) -> CGImage {
        let c = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString,size,nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 1 : 0,alpha: 1)]
        c.textPosition = CGPoint(x: 20,y: 30)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text,attributes: attributes)),c)
        return c.makeImage()!
    }

    func testActualCodeEntryRestoresReferenceSymbolsAndIndentation() async throws {
        for sample in OCRReferenceCorpus.samples where sample.category == "code" {
            let image = try OCRReferenceCorpus.render(sample)
            let actual = try await CaptureEngine.extract(image,destination: .code)
            XCTAssertEqual(actual,sample.expected,"Reference \(sample.id)")
        }
    }

    func testHeldOutFontsSizesAndContrastWithoutCodeContext() async throws {
        // Fixed before the first unified run; these sizes differ from the four
        // development reference images, and each glyph has no surrounding code.
        let cases: [(String, CGFloat, Bool)] = [("Monaco",24,false),("CourierNewPSMT",20,false),("Menlo-Bold",22,true)]
        for (font,size,dark) in cases {
            for text in ["}","->",">","→"] {
                let image = glyph(text,font: font,size: size,dark: dark)
                let result = try await OCRRecognitionWorker.run { try OCRCodeGlyphs.classify(image) }
                XCTAssertEqual(result?.text,text,"\(font) \(size) \(text)")
            }
        }
    }

    func testLettersNumbersAndTextureCannotBecomePunctuation() async throws {
        for text in ["S","1","l","I","f","0","t","Int"] {
            let image = glyph(text,font: "Menlo-Regular",size: 23)
            let result = try await OCRRecognitionWorker.run { try OCRCodeGlyphs.classify(image) }
            XCTAssertNil(result,"Negative glyph \(text)")
        }
        let texture = WorkflowCorpus.texture(width: 40,height: 40,seed: 413)
        let result = try await OCRRecognitionWorker.run { try OCRCodeGlyphs.classify(texture) }
        XCTAssertNil(result)
    }

    func testPreCancelledGlyphRecoveryRejectsWork() async {
        let image = glyph("}",font: "Menlo-Regular",size: 23)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OCRCodeGlyphs.classify(image)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled recovery must not return glyphs")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
