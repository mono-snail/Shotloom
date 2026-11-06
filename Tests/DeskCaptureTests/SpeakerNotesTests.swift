import XCTest
import AppKit
@testable import DeskCapture

final class SpeakerNotesTests: XCTestCase {
    func testScrollingPausesResumesAndClampsAfterStall() {
        var scroll = SpeakerNotesScroll()
        scroll.tick(at: 10, active: true, speed: 20, maximum: 100)
        scroll.tick(at: 10.1, active: true, speed: 20, maximum: 100)
        XCTAssertEqual(scroll.offset, 2, accuracy: 0.0001)
        scroll.tick(at: 20, active: false, speed: 20, maximum: 100)
        scroll.suspendClock()
        scroll.tick(at: 40, active: true, speed: 20, maximum: 100)
        XCTAssertEqual(scroll.offset, 2, accuracy: 0.0001)
        scroll.tick(at: 100, active: true, speed: 20, maximum: 100)
        XCTAssertEqual(scroll.offset, 7, accuracy: 0.0001)
        scroll.resize(from: 100, to: 200)
        XCTAssertEqual(scroll.offset, 14, accuracy: 0.0001)
        scroll.reset(); XCTAssertEqual(scroll.offset, 0)
    }
    func testBackgroundLayoutBoundsInputAndPreservesWholeScript() throws {
        var options = SpeakerNotesOptions(); options.width = 320; options.fontSize = 24
        let text = String(repeating: "中文 English narration 2026\n", count: 40)
        let layout = try SpeakerNotesLayout.create(text, options: options)
        XCTAssertGreaterThan(layout.lines.count, 40)
        XCTAssertGreaterThan(layout.height, 1000)
        XCTAssertEqual(layout.width, 320)
        XCTAssertThrowsError(try SpeakerNotesLayout.create(String(repeating: "a", count: 65_537), options: options))
        options.speed = .nan; XCTAssertThrowsError(try options.validate())
    }
    @MainActor func testPassivePanelCannotBecomeKeyAndClosesAtIdle() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No display available for native passive-panel coverage") }
        let suite = "DeskCapture.notes.tests.\(UUID())"
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { isolated.removePersistentDomain(forName: suite) }
        let controller = SpeakerNotesController(preferences: isolated)
        defer { controller.recordingStateChanged(.idle) }
        controller.text = "NOTE-CANARY-LOCAL-TEST\n第二行讲稿"
        controller.enabled = true
        let application = NSApplication.shared, previous = NSApplication.shared.keyWindow
        controller.configureCapture(excluded: true, screen: screen)
        controller.recordingStateChanged(.recording)
        await controller.awaitLayoutForDiagnostics()
        let panel = try XCTUnwrap(controller.panelForDiagnostics)
        XCTAssertTrue(panel.isVisible); XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(application.keyWindow === previous)
        controller.recordingStateChanged(.paused)
        XCTAssertTrue(panel.isVisible)
        controller.recordingStateChanged(.idle)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(isolated.object(forKey: "speakerNotesText"))
    }
    @MainActor func testUnknownCaptureExclusionDoesNotShowNotes() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No display available for exclusion-state coverage") }
        let suite = "DeskCapture.notes.unsafe.tests.\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = SpeakerNotesController(preferences: preferences)
        defer { controller.recordingStateChanged(.idle) }
        controller.text = "PRIVATE-NOTES-TEST"; controller.enabled = true
        controller.configureCapture(excluded: false, screen: screen)
        controller.recordingStateChanged(.recording)
        await controller.awaitLayoutForDiagnostics()
        XCTAssertTrue(controller.panelForDiagnostics == nil || controller.panelForDiagnostics?.isVisible == false)
        XCTAssertNotNil(controller.error)
    }
}
