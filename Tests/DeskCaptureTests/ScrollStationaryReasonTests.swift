import XCTest
@testable import DeskCapture

final class ScrollStationaryReasonTests: XCTestCase {
    func testMissingAndInvalidPositionRemainUnconfirmed() {
        XCTAssertEqual(ScrollCaptureStopReason.stationary(evidence: nil, direction: .reverse), .unconfirmed)
        let invalid = ScrollPositionEvidence(minimum: 0, maximum: 0, value: 0, container: .init(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(ScrollCaptureStopReason.stationary(evidence: invalid, direction: .forward), .unconfirmed)
    }
    func testNumericPositionDistinguishesBoundaryFromNoResponse() {
        let top = ScrollPositionEvidence(minimum: 0, maximum: 1, value: 0, container: .init(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(ScrollCaptureStopReason.stationary(evidence: top, direction: .reverse), .boundary)
        XCTAssertEqual(ScrollCaptureStopReason.stationary(evidence: top, direction: .forward), .unresponsive)
        let middle = ScrollPositionEvidence(minimum: 0, maximum: 1, value: 0.5, container: top.container)
        XCTAssertEqual(ScrollCaptureStopReason.stationary(evidence: middle, direction: .reverse), .unresponsive)
    }
}
