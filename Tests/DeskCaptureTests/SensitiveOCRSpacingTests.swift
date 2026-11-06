import XCTest
@testable import DeskCapture

final class SensitiveOCRSpacingTests: XCTestCase {
    func testEmailCandidatesTolerateHorizontalOCRSeparatorSpacesOnly() {
        for value in ["qa@example.invalid", "qa@example. invalid", "qa @ example . invalid", "qa\t@\texample.\tinvalid", "qa\u{00a0}@example.\u{2009}invalid", "name@sub . example. invalid"] {
            XCTAssertTrue(SensitiveContent.kinds(in: value).contains(.email), value)
        }
        for value in ["qa@\nexample.invalid", "qa@example.\ninvalid", "qa@exam ple.invalid", "price @ 3. 50", "PUBLIC WORKFLOW TEST"] {
            XCTAssertFalse(SensitiveContent.kinds(in: value).contains(.email), value)
        }
    }

    func testSpacingCandidatePreservesOriginalTextAndMaskGeometry() throws {
        let line = OCRLine(text: "qa@example. invalid", bounds: .init(x: 0.1, y: 0.4, width: 0.5, height: 0.08), confidence: 0.7)
        let result = try SensitiveRuleEvaluation.classify([line], kinds: [.email], rules: [], scope: .images)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.line.text, line.text)
        XCTAssertEqual(result.first?.line.bounds, line.bounds)
        XCTAssertEqual(result.first?.kinds, [.email])
    }
}
