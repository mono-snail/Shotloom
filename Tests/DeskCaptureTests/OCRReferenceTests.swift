import XCTest
@testable import DeskCapture

final class OCRReferenceTests: XCTestCase {
    func testInvalidAndLowConfidenceAreReviewHints() {
        for confidence: Float in [0, 0.79, .nan, -.infinity] {
            XCTAssertTrue(OCRLine(text: "unverified", bounds: .zero, confidence: confidence).needsReview)
        }
        XCTAssertFalse(OCRLine(text: "still may be wrong", bounds: .zero, confidence: 0.8).needsReview)
    }
    func testReferenceCorpusHasUniqueCasesAndUnclippedGlyphBounds() throws {
        XCTAssertEqual(OCRReferenceCorpus.samples.count, 20)
        XCTAssertEqual(Set(OCRReferenceCorpus.samples.map(\.id)).count, 20)
        for sample in OCRReferenceCorpus.samples {
            let image = try OCRReferenceCorpus.render(sample)
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertFalse(sample.expected.isEmpty)
            for bounds in OCRReferenceCorpus.referenceBounds(sample) {
                XCTAssertTrue(CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(bounds), sample.id)
            }
        }
    }
}
