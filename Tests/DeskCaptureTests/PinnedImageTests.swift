import XCTest
import AppKit
@testable import DeskCapture

final class PinnedImageTests: XCTestCase {
    @MainActor
    func testFirstClickOnImageStartsWindowDragInsteadOfBeingConsumed() throws {
        let panel = DragObservingPanel(contentRect: CGRect(x: 100, y: 100, width: 240, height: 180),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let image = PinnedImageContentView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        panel.contentView = image
        var closed = false; image.close = { closed = true }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 120, y: 80),
            modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(image.acceptsFirstMouse(for: event))
        image.mouseDown(with: event)
        XCTAssertTrue(panel.dragEvent === event)
        XCTAssertFalse(closed)
    }

    @MainActor
    func testDoubleClickClosesImageWithoutStartingAnotherDrag() throws {
        let panel = DragObservingPanel(contentRect: CGRect(x: 100, y: 100, width: 240, height: 180),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let image = PinnedImageContentView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        panel.contentView = image
        var closes = 0; image.close = { closes += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 120, y: 80),
            modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 2, clickCount: 2, pressure: 1))
        image.mouseDown(with: event)
        XCTAssertEqual(closes, 1)
        XCTAssertNil(panel.dragEvent)
    }
}

@MainActor
private final class DragObservingPanel: NSPanel {
    var dragEvent: NSEvent?
    override func performDrag(with event: NSEvent) { dragEvent = event }
}
