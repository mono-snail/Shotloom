import XCTest
@testable import DeskCapture

final class OCRLanguageReviewTests: XCTestCase {
    func testChineseDisagreementKeepsOriginalCandidateAndPureEnglish() {
        let rect = CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.1)
        let original = OCRLine(text: "#E Capture 2026", bounds: rect, confidence: 1)
        let chinese = OCRLine(text: "截图 Capture 2026", bounds: rect, confidence: 0.5)
        let selected = OCRLanguageReview.merge(automatic: [original], explicit: [chinese])[0]
        XCTAssertEqual(selected.text, chinese.text)
        XCTAssertEqual(selected.alternatives, [original.text])
        XCTAssertTrue(selected.needsReview)
        let english = OCRLine(text: "ABC xyz", bounds: rect, confidence: 1)
        let changedCase = OCRLine(text: "ABC XYZ", bounds: rect, confidence: 1)
        XCTAssertEqual(OCRLanguageReview.merge(automatic: [english], explicit: [changedCase])[0].text, "ABC xyz")
        let partial = OCRLine(text: "截图 Capture", bounds: CGRect(x: 0.1, y: 0.5, width: 0.35, height: 0.1), confidence: 1)
        XCTAssertEqual(OCRLanguageReview.merge(automatic: [original], explicit: [partial])[0].text, original.text)
        let otherRow = OCRLine(text: "截图 Capture 2026", bounds: rect.offsetBy(dx: 0, dy: 0.3), confidence: 1)
        XCTAssertEqual(OCRLanguageReview.merge(automatic: [original], explicit: [otherRow])[0].text, original.text)
    }
}
