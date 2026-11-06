import XCTest
@testable import DeskCapture

final class EditorTextDraftTests: XCTestCase {
    @MainActor func testLateRecognitionDoesNotRestoreTextTheUserCleared() {
        let draft = EditorTextDraft()
        draft.seed(nil)
        let requestRevision = draft.revision
        draft.edit("手动校对")
        draft.edit("")
        draft.acceptRecognition("迟到的识别内容", expectedRevision: requestRevision)
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(draft.modified)
    }

    @MainActor func testFinishingAnOlderSaveKeepsNewerEditsUnsaved() {
        let draft = EditorTextDraft()
        draft.seed("识别内容")
        draft.edit("第一版校对")
        let submittedRevision = draft.revision
        draft.edit("保存期间继续写的第二版")
        draft.saved(revision: submittedRevision)
        XCTAssertEqual(draft.text, "保存期间继续写的第二版")
        XCTAssertTrue(draft.modified)
        XCTAssertEqual(draft.feedback, L10n.text("已保存提交时的校对内容，当前修改尚未保存。"))
    }

    @MainActor func testRecognitionStartedBeforeASaveCannotReplaceTheSavedDraft() {
        let draft = EditorTextDraft()
        draft.seed(nil)
        let requestRevision = draft.revision
        draft.edit("已经确认的校对")
        draft.saved(revision: draft.revision)
        draft.acceptRecognition("旧识别结果", expectedRevision: requestRevision)
        XCTAssertEqual(draft.text, "已经确认的校对")
        XCTAssertFalse(draft.modified)
    }
}
