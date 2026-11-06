import XCTest
@testable import DeskCapture

final class RepairModelContextTests: XCTestCase {
    func testNearbyPreservesExistingCropAndExpandedAddsRealBackground() throws {
        let selection = CGRect(x: 400, y: 300, width: 100, height: 80)
        let size = CGSize(width: 1000, height: 800)
        XCTAssertEqual(try RepairModelContext.nearby.region(for: selection, imageSize: size),
                       CGRect(x: 375, y: 275, width: 150, height: 130))
        let expanded = try RepairModelContext.expanded.region(for: selection, imageSize: size)
        XCTAssertEqual(expanded, CGRect(x: 250, y: 150, width: 400, height: 380))
        XCTAssertTrue(expanded.contains(selection))
    }

    func testEdgeContextClipsToActualImageWithoutShiftingSelection() throws {
        let size = CGSize(width: 100, height: 60)
        for mode in RepairModelContext.allCases {
            let region = try mode.region(for: CGRect(x: 0, y: 0, width: 30, height: 40), imageSize: size)
            XCTAssertEqual(region.minX, 0)
            XCTAssertEqual(region.minY, 0)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(region))
            XCTAssertTrue(region.contains(CGRect(x: 0, y: 0, width: 30, height: 40)))
        }
    }

    func testInvalidAndOverBudgetRegionsAreRejected() {
        let size = CGSize(width: 100, height: 100)
        for region in [CGRect.zero, CGRect(x: -1, y: 0, width: 10, height: 10),
                       CGRect(x: 95, y: 95, width: 10, height: 10),
                       CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            XCTAssertThrowsError(try RepairModelContext.expanded.region(for: region, imageSize: size))
        }
        XCTAssertThrowsError(try RepairModelContext.expanded.region(for: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                                   imageSize: CGSize(width: 5000, height: 5000)))
    }
}
