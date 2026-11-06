import XCTest
import AppKit
@testable import DeskCapture

final class CaptureWindowInfoTests: XCTestCase {
    private func row(_ id: UInt32, pid: Int32 = 123, frame: CGRect = CGRect(x: 20, y: 30, width: 600, height: 400)) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id),
         kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowIsOnscreen as String: NSNumber(value: true)]
    }
    func testMissingOrReorderedWindowCannotResolveToAnotherWindow() throws {
        XCTAssertNil(CaptureWindowInfo.resolve(17, in: [row(16), row(18)]))
        XCTAssertNil(CaptureWindowInfo.resolve(0, in: [row(0)]))
        let value = try XCTUnwrap(CaptureWindowInfo.resolve(17, in: [row(18), row(17), row(16)]))
        XCTAssertEqual(value.id, 17)
        XCTAssertEqual(value.processID, 123)
        XCTAssertEqual(value.frame, CGRect(x: 20, y: 30, width: 600, height: 400))
        XCTAssertEqual(value.isOnScreen, true)
    }
    func testInvalidGeometryDoesNotBecomeAUsableCaptureTarget() {
        XCTAssertNil(CaptureWindowInfo.resolve(17, in: [row(17, frame: .zero)]))
        var missingBounds = row(17)
        missingBounds.removeValue(forKey: kCGWindowBounds as String)
        XCTAssertNil(CaptureWindowInfo.resolve(17, in: [missingBounds]))
    }
    @MainActor func testNativeQueryFindsActualWindowIDWithoutBoxingIt() async throws {
        _ = NSApplication.shared
        let origin = try XCTUnwrap(NSScreen.main).visibleFrame.origin
        let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 160, height: 100)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let id = CGWindowID(window.windowNumber)
        let value = try XCTUnwrap(CaptureWindowInfo.read(id))
        XCTAssertEqual(value.id, id)
        XCTAssertEqual(value.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(value.frame.size, CGSize(width: 160, height: 100))
        XCTAssertNil(CaptureWindowInfo.read(kCGNullWindowID))
    }
}
