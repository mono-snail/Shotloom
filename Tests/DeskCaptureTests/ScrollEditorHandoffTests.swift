import XCTest
@testable import DeskCapture

final class ScrollEditorHandoffTests: XCTestCase {
    @MainActor func testFailedEditorHandoffRetainsCaptureForRetryAndExport() async throws {
        let stitcher = try ScrollStitcher(detectsFixedEdges: false)
        try stitcher.append(WorkflowCorpus.texture(width: 200, height: 300, seed: 42))
        let capture = ScrollCapture(stitcher: stitcher)
        defer { capture.onPrepareEditor = nil; capture.onFinish = nil }
        var delivered = false
        capture.onPrepareEditor = { _ in throw CaptureError.message("模拟历史写入失败") }
        capture.onFinish = { _, _ in delivered = true }
        await capture.finish(output: .editor)
        XCTAssertFalse(delivered)
        XCTAssertTrue(capture.active); XCTAssertTrue(capture.paused)
        XCTAssertFalse(capture.finishing)
        XCTAssertEqual(capture.frames, 1)
        XCTAssertEqual(capture.preview.width, 200); XCTAssertEqual(capture.preview.height, 300)
        XCTAssertTrue(capture.warning?.contains("模拟历史写入失败") == true)
    }

    @MainActor func testSuccessfulHandoffCommitsBeforeClosingTheCapture() async throws {
        let stitcher = try ScrollStitcher(detectsFixedEdges: false)
        try stitcher.append(WorkflowCorpus.texture(width: 200, height: 300, seed: 43))
        let capture = ScrollCapture(stitcher: stitcher)
        defer { capture.onPrepareEditor = nil; capture.onFinish = nil }
        var order: [String] = []
        capture.onPrepareEditor = { image in
            XCTAssertTrue(capture.active); XCTAssertTrue(capture.finishing)
            XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 300)
            order.append("committed")
        }
        capture.onFinish = { _, output in
            guard case .editor = output else { XCTFail("Unexpected delivery"); return }
            XCTAssertFalse(capture.active); XCTAssertFalse(capture.finishing)
            order.append("delivered")
        }
        await capture.finish(output: .editor)
        XCTAssertEqual(order, ["committed", "delivered"])
    }
}
