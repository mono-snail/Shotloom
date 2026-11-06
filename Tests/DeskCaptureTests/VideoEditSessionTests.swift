import XCTest
@testable import DeskCapture

final class VideoEditSessionTests: XCTestCase {
    @MainActor private func state(_ start: Double = 0) -> VideoEditState {
        .init(effects: .init(), captions: [], lenses: [], start: start, end: 10)
    }
    @MainActor private func record(_ state: VideoEditState, in session: VideoEditSession) {
        // Each helper call represents a distinct user event. XCTest invokes
        // both synchronously, without AppKit ending its implicit event group.
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.record(state)
        session.undoManager.endUndoGrouping()
    }
    @MainActor func testUndoRedoTracksSavedBaseline() {
        let session = VideoEditSession()
        session.begin(state())
        record(state(2), in: session)
        session.markSaved(state(2))
        XCTAssertFalse(session.dirty)
        session.undoManager.undo()
        XCTAssertTrue(session.dirty)
        session.undoManager.redo()
        XCTAssertFalse(session.dirty)
        session.detach()
    }
    @MainActor func testFinishingAnOlderSaveDoesNotClearLaterEdits() {
        let session = VideoEditSession()
        session.begin(state())
        record(state(2), in: session)
        let saving = state(2)
        record(state(3), in: session)
        session.markSaved(saving)
        XCTAssertTrue(session.dirty)
        session.undoManager.undo()
        XCTAssertFalse(session.dirty)
        session.detach()
    }
    @MainActor func testRestoreNotificationDoesNotCreateAnotherUndo() {
        let session = VideoEditSession()
        session.begin(state())
        session.apply = { session.record($0) }
        record(state(2), in: session)
        session.undoManager.undo()
        XCTAssertFalse(session.undoManager.canUndo)
        XCTAssertTrue(session.undoManager.canRedo)
        XCTAssertFalse(session.dirty)
        session.detach()
    }
    @MainActor func testReopeningStartsNewHistory() {
        let session = VideoEditSession()
        session.begin(state())
        record(state(2), in: session)
        session.begin(state(4))
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.undoManager.canUndo)
        XCTAssertFalse(session.undoManager.canRedo)
        session.detach()
    }
}
