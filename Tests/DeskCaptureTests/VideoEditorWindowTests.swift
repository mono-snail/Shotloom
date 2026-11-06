import XCTest
import AppKit
@testable import DeskCapture

final class VideoEditorWindowTests: XCTestCase {
    func testEditorIsCenteredAndContainedOnSmallAndOffsetScreens() {
        for visible in [NSRect(x: 0, y: 25, width: 1440, height: 875),
                        NSRect(x: -1280, y: 40, width: 1280, height: 680),
                        NSRect(x: 1440, y: -400, width: 800, height: 560)] {
            let frame = VideoResultPanel.initialFrame(in: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.midY, visible.midY)
        }
    }
    @MainActor
    func testProductionEntryOpensMovableResizableEditorInsteadOfFloatingPanel() throws {
        _ = NSApplication.shared
        let coordinator = AppCoordinator()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("video-window-\(UUID()).mp4")
        coordinator.showVideo(source, imported: true)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == L10n.text("视频编辑 — \(source.lastPathComponent)") })
        defer { window.close() }
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.isMovable)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 780, height: 540))
        window.setContentSize(window.contentMinSize)
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, 780, accuracy: 1)
        window.setContentSize(NSSize(width: 1120, height: 720))
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, 1120, accuracy: 1)
        withExtendedLifetime(coordinator) {}
    }

}
