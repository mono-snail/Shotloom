import XCTest
import CoreText
@testable import DeskCapture

final class OCRFontFittingTests: XCTestCase {
    // Fixed references use installed fonts, generated pixels and independent CoreText bounds.
    // These cases are written for the final unified run; adding them is not a pass.
    func testKnownInstalledFontIsAmongFittedCandidatesAndSizeIsClose() async throws {
        for (name, text) in [("PingFangSC-Regular", "Price 128.50 本地处理"),
                                   ("Menlo-Regular", "let value = 709;"),
                                   ("Georgia", "Contrast Aa 123")] {
            let image = WorkflowCorpus.text(text, font: name) // Existing corpus renders at 32 px.
            let font = CTFontCreateWithName(name as CFString, 32, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let glyph = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).offsetBy(dx: 48, dy: 528)
            let bounds = CGRect(x: glyph.minX/1600, y: glyph.minY/600, width: glyph.width/1600, height: glyph.height/600)
            let fitted = try await OCRFontFitting.fit(image: image, bounds: bounds, text: text)
            let match = try XCTUnwrap(fitted.candidates.first { $0.fit.fontName == name })
            XCTAssertEqual(match.fit.sizePixels, 32, accuracy: 2)
            XCTAssertEqual(match.fit.baselinePixels, 528, accuracy: 3)
            XCTAssertTrue(match.fit.maskError.isFinite)
            XCTAssertGreaterThan(fitted.fontsCompared, 0)
        }
    }
    func testRejectsOversizedOrInvalidRequests() async {
        let image = WorkflowCorpus.texture(width: 40, height: 40, seed: 42)
        do {
            _ = try await OCRFontFitting.fit(image: image, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), text: String(repeating: "x", count: 129))
            XCTFail("Expected a bounded text request")
        } catch { }
    }
    func testFitMetadataSurvivesProjectRoundTrip() throws {
        let image = WorkflowCorpus.texture(width: 100, height: 100, seed: 42)
        let document = AnnotationDocument(image: image)
        var mark = Annotation(tool: .text, points: [CGPoint(x: 0.1, y: 0.1)])
        mark.fontName = "Menlo-Regular"; mark.fontTracking = 0.75; mark.textOriginOffset = CGPoint(x: 2, y: 14)
        document.add(mark)
        let restored = try AnnotationDocument(projectData: document.projectData())
        XCTAssertEqual(restored.marks.first?.fontTracking, 0.75)
        XCTAssertEqual(restored.marks.first?.textOriginOffset, CGPoint(x: 2, y: 14))
    }
}
