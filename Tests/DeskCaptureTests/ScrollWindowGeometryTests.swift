import XCTest
@testable import DeskCapture

final class ScrollWindowGeometryTests: XCTestCase {
    func testMainScreenWindowConvertsFromWindowServerCoordinates() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 600)
        XCTAssertEqual(ScrollWindowGeometry.localRect(frame, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), desktopTop: 900),
                       CGRect(x: 100, y: 200, width: 900, height: 600))
    }

    func testSecondaryDisplayCanHaveNegativeOriginAndDifferentVerticalOffset() {
        let frame = CGRect(x: -1200, y: 800, width: 600, height: 400)
        XCTAssertEqual(ScrollWindowGeometry.localRect(frame, screenFrame: CGRect(x: -1440, y: 300, width: 1440, height: 900), desktopTop: 1800),
                       CGRect(x: 240, y: 300, width: 600, height: 400))
    }

    func testWindowSourceRetainsWholeWindowAcrossScreenBoundary() {
        let frame = CGRect(x: -300, y: 100, width: 1600, height: 600)
        let local = ScrollWindowGeometry.localRect(frame, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), desktopTop: 900)
        XCTAssertEqual(local, CGRect(x: -300, y: 200, width: 1600, height: 600))
        XCTAssertEqual(local.size, frame.size)
    }

    func testMovementCanContinueButAResizedWindowCannotReuseTheSameRaster() {
        let initial = CGRect(x: 100, y: 100, width: 900, height: 600)
        XCTAssertTrue(ScrollWindowGeometry.sizeMatches(initial, initial.offsetBy(dx: -800, dy: 350)))
        XCTAssertFalse(ScrollWindowGeometry.sizeMatches(initial, CGRect(x: 100, y: 100, width: 940, height: 600)))
        XCTAssertFalse(ScrollWindowGeometry.sizeMatches(initial, CGRect(x: 100, y: 100, width: 900, height: 640)))
    }
}
