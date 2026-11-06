import XCTest
import AppKit
import SwiftUI
@testable import DeskCapture

final class CapturePanelGeometryTests: XCTestCase {
    func testExpandedRecordingPanelFitsAtBottomAndOnOffsetDisplays() {
        for screen in [CGRect(x: 0, y: 80, width: 1440, height: 780),
                       CGRect(x: -1920, y: -1080, width: 1920, height: 1040)] {
            let old = CGRect(x: screen.maxX - 320, y: screen.minY + 10, width: 310, height: 44)
            let expanded = CapturePanelGeometry.resized(old, size: CGSize(width: 310, height: 255), visibleFrame: screen)
            XCTAssertTrue(screen.contains(expanded))
            XCTAssertEqual(expanded.size, CGSize(width: 310, height: 255))
            let collapsed = CapturePanelGeometry.resized(expanded, size: old.size, visibleFrame: screen)
            XCTAssertEqual(collapsed.maxY, expanded.maxY)
            XCTAssertTrue(screen.contains(collapsed))
        }
    }

    func testPreviouslyOffscreenPanelRecoversAtEveryEdge() {
        let screen = CGRect(x: -1200, y: 40, width: 1200, height: 760)
        for point in [CGPoint(x: -2000, y: -500), CGPoint(x: 300, y: 1500)] {
            let frame = CapturePanelGeometry.resized(CGRect(origin: point, size: CGSize(width: 310, height: 44)),
                size: CGSize(width: 310, height: 132), visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.size, CGSize(width: 310, height: 132))
        }
    }

    @MainActor
    func testRecordingSelectionToolbarAtBottomCanMoveWithoutMovingSelection() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(screen.frame.width), height: Int(screen.frame.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(bitmap.makeImage())
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: image), mode: .recording, windows: [])
        let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = view
        let selection = CGRect(x: 40, y: 5, width: 400, height: 160)
        view.setInitialSelectionForPreview(selection)
        let toolbar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
        let usable = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        XCTAssertTrue(usable.contains(toolbar.frame))
        let initial = toolbar.frame.origin
        toolbar.rootView.moveToolbar(CGSize(width: 100, height: 100))
        XCTAssertNotEqual(toolbar.frame.origin, initial)
        XCTAssertEqual(view.selection, selection)
        toolbar.rootView.moveToolbar(CGSize(width: -10_000, height: -10_000))
        XCTAssertTrue(usable.contains(toolbar.frame))
        XCTAssertEqual(view.selection, selection)
    }
}
