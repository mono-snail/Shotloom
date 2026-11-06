import XCTest
import AppKit
@testable import DeskCapture

final class RecordingRegionOverlayTests: XCTestCase {
    @MainActor
    func testRenderedGuideDoesNotCoverRecordedPixels() throws {
        let view = RecordingRegionOverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.recordingRect = CGRect(x: 20, y: 20, width: 60, height: 60)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 50, y: 50)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 20, y: 50)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 10, y: 50)).alphaComponent, 0.22, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 19, y: 50)).alphaComponent, 0.85)
    }

    @MainActor
    func testMaskLeavesRecordingAreaClearAndMovesWithRegion() {
        let view = RecordingRegionOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        view.recordingRect = CGRect(x: 100, y: 200, width: 400, height: 300)
        XCTAssertFalse(view.maskPath.contains(CGPoint(x: 300, y: 350)))
        XCTAssertTrue(view.maskPath.contains(CGPoint(x: 50, y: 350)))
        XCTAssertTrue(view.maskPath.contains(CGPoint(x: 300, y: 600)))
        view.recordingRect = CGRect(x: 600, y: 200, width: 300, height: 300)
        XCTAssertTrue(view.maskPath.contains(CGPoint(x: 300, y: 350)))
        XCTAssertFalse(view.maskPath.contains(CGPoint(x: 750, y: 350)))
    }

    @MainActor
    func testOverlayAllowsInteractionReusesPanelsAndClosesAllWindows() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let overlay = RecordingRegionOverlay()
        defer { overlay.close() }
        let bounds = CGRect(x: screen.frame.minX + 30, y: screen.frame.minY + 40, width: 200, height: 150)
        overlay.update(bounds: bounds, screens: [screen])
        let panel = try XCTUnwrap(overlay.panels.first)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.frame, screen.frame)
        let view = try XCTUnwrap(panel.contentView as? RecordingRegionOverlayView)
        XCTAssertEqual(view.recordingRect, CGRect(x: 30, y: 40, width: 200, height: 150))
        overlay.update(bounds: bounds.offsetBy(dx: 10, dy: 20), screens: [screen])
        XCTAssertTrue(overlay.panels.first === panel)
        XCTAssertEqual(view.recordingRect.origin, CGPoint(x: 40, y: 60))
        overlay.close()
        XCTAssertTrue(overlay.panels.isEmpty)
        XCTAssertFalse(panel.isVisible)
    }
}
