import XCTest
@testable import DeskCapture

final class ScrollSelectionResolverTests: XCTestCase {
    func testCrossWindowSelectionBecomesVisibleRegionInCenteredWindow() throws {
        let result = try XCTUnwrap(ScrollSelectionResolver.resolve(CGRect(x: 0, y: 0, width: 900, height: 650), windows: [
            .init(id: 1, title: "浏览器", frame: CGRect(x: 120, y: 80, width: 650, height: 500)),
            .init(id: 2, title: "文档", frame: CGRect(x: 0, y: 0, width: 400, height: 650))]))
        XCTAssertEqual(result.window.id, 1)
        XCTAssertEqual(result.rect, CGRect(x: 120, y: 80, width: 650, height: 500))
        XCTAssertTrue(result.adjusted)
    }

    func testForegroundWindowNeverLeaksIntoResolvedBackgroundSelection() throws {
        let blocker = CGRect(x: 0, y: 0, width: 150, height: 600)
        let result = try XCTUnwrap(ScrollSelectionResolver.resolve(CGRect(x: 0, y: 0, width: 800, height: 600), windows: [
            .init(id: 1, title: "前景", frame: blocker),
            .init(id: 2, title: "浏览器", frame: CGRect(x: 0, y: 0, width: 800, height: 600))]))
        XCTAssertEqual(result.window.id, 2)
        XCTAssertEqual(result.rect, CGRect(x: 150, y: 0, width: 650, height: 600))
        XCTAssertTrue(result.rect.intersection(blocker).width == 0)
    }

    func testValidSelectionIsUnchangedAndDesktopSelectionIsRejected() throws {
        let region = CGRect(x: -500, y: 80, width: 200, height: 300)
        let windows = [ScrollSelectionResolver.Window(id: 7, title: "副屏", frame: CGRect(x: -600, y: 0, width: 400, height: 600))]
        let result = try XCTUnwrap(ScrollSelectionResolver.resolve(region, windows: windows))
        XCTAssertEqual(result.rect, region); XCTAssertFalse(result.adjusted)
        XCTAssertNil(ScrollSelectionResolver.resolve(CGRect(x: 50, y: 50, width: 100, height: 100), windows: windows))
        XCTAssertNil(ScrollSelectionResolver.resolve(CGRect(x: -500, y: 80, width: 20, height: 20), windows: windows))
    }
}
