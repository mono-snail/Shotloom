import XCTest
import AppKit
@testable import DeskCapture

final class LauncherPanelTests: XCTestCase {
    @MainActor
    func testReopeningRepairsHiddenTransparentLoweredAndOffscreenPanel() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = LauncherPanel(contentRect: NSRect(x: -10000, y: -10000, width: 328, height: 422),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        for _ in 0..<3 {
            panel.orderOut(nil)
            panel.level = .normal
            panel.alphaValue = 0
            panel.hidesOnDeactivate = true
            panel.collectionBehavior = []
            panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            panel.restorePresentation(in: screen.visibleFrame)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
            XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        }
    }

    @MainActor
    func testFloatingPanelRemainsVisibleAfterLosingFocusAndCanBeHiddenAndReopened() {
        _ = NSApplication.shared
        let panel = LauncherPanel(contentRect: NSRect(x: 40, y: 40, width: 328, height: 422),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        panel.makeKeyAndOrderFront(nil)
        panel.resignKey()
        XCTAssertTrue(panel.isVisible)
        panel.cancelOperation(nil)
        XCTAssertFalse(panel.isVisible)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.isVisible)
        panel.performClose(nil)
        XCTAssertFalse(panel.isVisible)
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.isVisible)
    }
}
