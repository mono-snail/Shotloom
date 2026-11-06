import XCTest
@testable import DeskCapture

final class ScrollPositionEvidenceTests: XCTestCase {
    private func position(_ value: Double, minimum: Double = 0, maximum: Double = 1) -> ScrollPositionEvidence {
        ScrollPositionEvidence(minimum: minimum, maximum: maximum, value: value,
                               container: CGRect(x: 20, y: 40, width: 800, height: 600))
    }
    func testNearEndIsNotTheEndAndReverseUsesTheOtherBoundary() {
        XCTAssertFalse(position(0.999).atBoundary(direction: .forward))
        XCTAssertTrue(position(1).atBoundary(direction: .forward))
        XCTAssertFalse(position(1).atBoundary(direction: .reverse))
        XCTAssertTrue(position(0).atBoundary(direction: .reverse))
        XCTAssertFalse(position(0).atBoundary(direction: .forward))
    }
    func testInvalidOrUnsupportedRangesCannotCertifyCompletion() {
        for evidence in [position(.nan), position(.infinity), position(2), position(-1),
                         position(0, maximum: 0), position(0, minimum: 1, maximum: 0),
                         position(0, minimum: -.greatestFiniteMagnitude, maximum: .greatestFiniteMagnitude)] {
            XCTAssertFalse(evidence.valid)
            XCTAssertFalse(evidence.atBoundary(direction: .forward))
            XCTAssertFalse(evidence.atBoundary(direction: .reverse))
        }
    }
}
