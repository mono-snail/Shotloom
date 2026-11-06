import XCTest
import AppKit
@testable import DeskCapture

final class StatusGuideTests: XCTestCase {
    func testGuideStaysBelowIconAndOnTheIconsScreen() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1280, y: 100, width: 1280, height: 720)] {
            for x in [screen.minX + 20, screen.midX, screen.maxX - 20] {
                let anchor = NSRect(x: x - 10, y: screen.maxY - 24, width: 20, height: 20)
                let frame = StatusGuideGeometry.frame(anchor: anchor, screen: screen)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(frame.maxY, anchor.minY)
                XCTAssertGreaterThanOrEqual(anchor.midX, frame.minX)
                XCTAssertLessThanOrEqual(anchor.midX, frame.maxX)
            }
        }
    }
    @MainActor
    func testRepeatedPresentationReusesOneNonactivatingGuideAndDismisses() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "◎"
        defer { NSStatusBar.system.removeStatusItem(item) }
        let guide = StatusItemGuideController()
        defer { guide.dismiss() }
        guide.show(relativeTo: item, openMenu: {})
        try await Task.sleep(for: .milliseconds(450))
        let panel = try XCTUnwrap(guide.panel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(try XCTUnwrap(panel.contentView).acceptsFirstMouse(for: nil))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        for _ in 0..<3 {
            guide.show(relativeTo: item, openMenu: {})
            XCTAssertTrue(guide.panel === panel)
        }
        guide.dismiss()
        XCTAssertFalse(panel.isVisible)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(panel.isVisible)
    }
    @MainActor
    func testGuideAutomaticallyClosesAndCanBeShownAgain() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "◎"
        defer { NSStatusBar.system.removeStatusItem(item) }
        let guide = StatusItemGuideController()
        defer { guide.dismiss() }
        guide.show(relativeTo: item, openMenu: {})
        try await Task.sleep(for: .milliseconds(450))
        let panel = try XCTUnwrap(guide.panel)
        XCTAssertTrue(panel.isVisible)
        try await Task.sleep(for: .milliseconds(10000))
        XCTAssertFalse(panel.isVisible)
        guide.show(relativeTo: item, openMenu: {})
        XCTAssertTrue(guide.panel === panel)
        XCTAssertTrue(panel.isVisible)
    }

}
