import XCTest
import AppKit
@testable import DeskCapture

final class ScrollContainerTests: XCTestCase {
    @MainActor
    func testDistributedProbesFindFreeAreaBeyondHUDAndCursorWithoutBypassingCovers() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let hud = CGRect(x: 0, y: 0, width: 700, height: 1000)
        let cursor = CGRect(x: 740, y: 480, width: 28, height: 40)
        let windows: [[String: Any]] = [
            [kCGWindowNumber as String: UInt32(1), kCGWindowBounds as String: cursor.dictionaryRepresentation],
            [kCGWindowNumber as String: UInt32(2), kCGWindowBounds as String: hud.dictionaryRepresentation],
            [kCGWindowNumber as String: UInt32(9), kCGWindowBounds as String: screen.dictionaryRepresentation]]
        let point = try XCTUnwrap(ScrollCapture.unobscuredScrollPoint(rect: screen, screenFrame: screen, desktopTop: 1000,
                                                                     target: 9, windows: windows))
        XCTAssertTrue(screen.contains(point)); XCTAssertFalse(hud.contains(point)); XCTAssertFalse(cursor.contains(point))
        XCTAssertNil(ScrollCapture.unobscuredScrollPoint(rect: screen, screenFrame: screen, desktopTop: 1000,
                                                        target: 9, windows: windows, avoiding: [screen]))
        let covered = [[kCGWindowNumber as String: UInt32(2), kCGWindowBounds as String: screen.dictionaryRepresentation]] + windows
        XCTAssertNil(ScrollCapture.unobscuredScrollPoint(rect: screen, screenFrame: screen, desktopTop: 1000, target: 9, windows: covered))
    }
    func testScreenshotSurfaceNeedsFreshPixelProofAndExactSystemIdentity() {
        let system = "/System/Library/CoreServices/screencaptureui.app"
        XCTAssertFalse(ScrollContainerDetector.mayAdjudicateSystemSurface(bundlePath: system, layer: 24, displayPixelsVerified: false))
        XCTAssertTrue(ScrollContainerDetector.mayAdjudicateSystemSurface(bundlePath: system, layer: 24, displayPixelsVerified: true))
        for path in [nil, "/Applications/screencaptureui.app", "/tmp/Dock.app", "/Applications/DeskCapture.app"] as [String?] {
            XCTAssertFalse(ScrollContainerDetector.mayAdjudicateSystemSurface(bundlePath: path, layer: 24, displayPixelsVerified: true))
        }
        XCTAssertFalse(ScrollContainerDetector.mayAdjudicateSystemSurface(bundlePath: system, layer: 0, displayPixelsVerified: true))
        XCTAssertFalse(ScrollContainerDetector.mayAdjudicateSystemSurface(bundlePath: system, layer: nil, displayPixelsVerified: true))
    }
    func testGlobalHitMustBelongToOriginalProcessAndWindow() {
        let frame = CGRect(x: 300, y: 76, width: 600, height: 832)
        XCTAssertTrue(ScrollContainerDetector.matchesWindow(owner: 20, pid: 20, frame: frame, expected: frame))
        XCTAssertFalse(ScrollContainerDetector.matchesWindow(owner: 21, pid: 20, frame: frame, expected: frame))
        XCTAssertFalse(ScrollContainerDetector.matchesWindow(owner: 20, pid: 20, frame: frame.offsetBy(dx: 20, dy: 0), expected: frame))
        XCTAssertFalse(ScrollContainerDetector.matchesWindow(owner: 20, pid: 20, frame: CGRect(x: 300, y: 76, width: 400, height: 832), expected: frame))
    }
    func testNestedContainerChoosesInnerAndKeepsCaptureSelection() throws {
        let selection = CGRect(x: 100, y: 100, width: 800, height: 600)
        let outer = try XCTUnwrap(ScrollContainerDetector.candidate(frame: selection, selection: selection, depth: 4))
        let inner = try XCTUnwrap(ScrollContainerDetector.candidate(frame: CGRect(x: 300, y: 200, width: 400, height: 300), selection: selection, depth: 1))
        XCTAssertEqual(ScrollContainerDetector.preferred([outer, inner], selection: selection), inner)
        XCTAssertEqual(ScrollContainerDetector.pointRect(inner, selection: selection), CGRect(x: 304, y: 204, width: 392, height: 292))
        XCTAssertEqual(selection.width, 800)
    }
    func testUnknownOrOffCenterContainerIsNotGuessed() {
        let selection = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let side = ScrollContainerDetector.candidate(frame: CGRect(x: 0, y: 0, width: 200, height: 600), selection: selection, depth: 0)!
        XCTAssertNil(ScrollContainerDetector.preferred([side], selection: selection))
        XCTAssertNil(ScrollContainerDetector.candidate(frame: CGRect(x: 2000, y: 0, width: 200, height: 600), selection: selection, depth: 0))
        XCTAssertNil(ScrollContainerDetector.candidate(frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600), selection: selection, depth: 0))
    }
    @MainActor
    func testOuterContainerDeliveryAvoidsInnerAndForeignWindows() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let windows: [[String: Any]] = [[kCGWindowNumber as String: UInt32(9), kCGWindowBounds as String: screen.dictionaryRepresentation]]
        let inner = CGRect(x: 250, y: 0, width: 500, height: 1000)
        let point = ScrollCapture.unobscuredScrollPoint(rect: screen, screenFrame: screen, desktopTop: 1000,
                                                       target: 9, windows: windows, avoiding: [inner])
        XCTAssertEqual(point, CGPoint(x: 750, y: 500))
        XCTAssertNil(ScrollCapture.unobscuredScrollPoint(rect: screen, screenFrame: screen, desktopTop: 1000,
                                                        target: 9, windows: windows, avoiding: [screen]))
    }
    @MainActor
    func testManualTargetCorrectionPreservesAcceptedTilesAndRejectsInvalidPoint() throws {
        let page = WorkflowCorpus.texture(width: 400, height: 600, seed: 42)
        let stitcher = try ScrollStitcher(); try stitcher.append(page)
        let model = ScrollCapture(stitcher: stitcher)
        let old = model.preview
        model.setManualScrollPoint(x: .nan, y: 0.5)
        XCTAssertNil(model.manualScrollPoint)
        model.setManualScrollPoint(x: 0.2, y: 0.8)
        XCTAssertNotNil(model.manualScrollPoint)
        XCTAssertTrue(model.paused)
        XCTAssertEqual(model.frames, 1)
        XCTAssertEqual(model.preview.width, old.width)
        XCTAssertEqual(model.preview.height, old.height)
        model.continueManually()
        XCTAssertFalse(model.automatic)
        XCTAssertFalse(model.paused)
    }
}
