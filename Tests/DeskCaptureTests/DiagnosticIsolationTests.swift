import XCTest
import AppKit
@testable import DeskCapture

final class DiagnosticIsolationTests: XCTestCase {
    func testLazyDefaultStoreUsesConfiguredWorkspaceAndExplicitDirectoryTakesPrecedence() throws {
        guard let path = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] else {
            throw XCTSkip("Run with the isolated workspace configured by check-quality.sh")
        }
        // Deferred stores cannot read any history before these ownership checks,
        // including if a future regression accidentally selects the real home.
        let store = CaptureStore(pruneOnInit: false, deferLoading: true)
        let expected = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("captures", isDirectory: true)
        XCTAssertEqual(store.directory.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertTrue(store.records.isEmpty)
        let explicit = FileManager.default.temporaryDirectory.appendingPathComponent("explicit-capture-\(UUID())", isDirectory: true)
        let overridden = CaptureStore(directory: explicit, pruneOnInit: false, deferLoading: true)
        XCTAssertEqual(overridden.directory.standardizedFileURL, explicit.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: explicit.path))
    }

    @MainActor
    func testReopeningVisibleEditorDoesNotCreateGuideOrReplaceDraft() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu, previousAppearance = NSApp.appearance
        let previousPolicy = NSApp.activationPolicy()
        let delegate = ApplicationDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            NSApp.mainMenu = previousMenu; NSApp.appearance = previousAppearance
            _ = NSApp.setActivationPolicy(previousPolicy)
        }
        // Bootstrap a real status item/guide so the old unconditional reopen
        // implementation would visibly recreate it and fail this regression.
        for _ in 0..<40 where delegate.launchGuide.panel?.isVisible != true { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(delegate.launchGuide.panel?.isVisible == true, "Status item fixture must be ready")
        delegate.launchGuide.dismiss()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 260, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        let text = NSTextView(frame: window.contentView!.bounds); text.string = "owned draft fixture"
        window.contentView = text; window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
        defer { window.close() }
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertFalse(delegate.launchGuide.panel?.isVisible == true)
        XCTAssertEqual(text.string, "owned draft fixture")
        XCTAssertTrue(window.firstResponder === text); XCTAssertTrue(window.isVisible)
    }

}
