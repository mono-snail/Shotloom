import XCTest
import AppKit
@testable import DeskCapture

final class StatusMenuTests: XCTestCase {
    @MainActor
    func testApplicationMenuProvidesSettingsCommandComma() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let delegate = ApplicationDelegate()
        delegate.makeApplicationMenu()
        let applicationMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let settings = try XCTUnwrap(applicationMenu.items.first { $0.keyEquivalent == "," })
        XCTAssertEqual(settings.title, L10n.text("设置…"))
        XCTAssertTrue(settings.target === delegate)
        XCTAssertEqual(settings.action.map(NSStringFromSelector), "showSettings")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
    }
    func testCaptureActionsCannotStartDuringOtherWork() {
        for state in [StatusMenuState(capturing: true), StatusMenuState(scrolling: true),
                      StatusMenuState(recording: .preparing), StatusMenuState(recording: .recording),
                      StatusMenuState(recording: .paused), StatusMenuState(recording: .finishing)] {
            for mode in CaptureMode.allCases { XCTAssertFalse(state.allows(.capture(mode))) }
            XCTAssertFalse(state.allows(.recordWindow))
            XCTAssertFalse(state.allows(.delayedCapture(5)))
            XCTAssertFalse(state.allows(.repeatRegion))
            XCTAssertTrue(state.allows(.settings))
        }
    }
    func testRepeatAndAllScreensDependOnAvailableTargets() {
        let empty = StatusMenuState()
        XCTAssertFalse(empty.allows(.repeatRegion))
        XCTAssertFalse(empty.allows(.capture(.allScreens)))
        XCTAssertTrue(empty.allows(.capture(.region)))
        let ready = StatusMenuState(canRepeat: true, screenCount: 2)
        XCTAssertTrue(ready.allows(.repeatRegion))
        XCTAssertTrue(ready.allows(.capture(.allScreens)))
    }
    func testRecordingControlsOnlyOperateAnActiveRecording() {
        for recording in [RecordingState.idle, .preparing, .recording, .paused, .finishing] {
            let state = StatusMenuState(recording: recording)
            let active = recording == .recording || recording == .paused
            XCTAssertEqual(state.allows(.stopRecording), active)
            XCTAssertEqual(state.allows(.pauseRecording), active)
            XCTAssertFalse(state.allows(.copyScrolling))
        }
    }
    func testScrollingCannotFinishWhileWritingOrProcessing() {
        XCTAssertFalse(StatusMenuState().allows(.copyScrolling))
        let available = StatusMenuState(scrolling: true)
        XCTAssertTrue(available.allows(.copyScrolling)); XCTAssertTrue(available.allows(.saveScrolling))
        let busy = StatusMenuState(scrolling: true, scrollingBusy: true)
        XCTAssertFalse(busy.allows(.copyScrolling)); XCTAssertFalse(busy.allows(.saveScrolling))
        XCTAssertTrue(busy.allows(.history))
    }
}
