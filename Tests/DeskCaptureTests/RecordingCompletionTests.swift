import XCTest
@testable import DeskCapture

final class RecordingCompletionTests: XCTestCase {
    @MainActor
    func testCompletionBeforePauseIsNotLostAndDuplicateErrorCannotReplaceSuccess() async throws {
        let completion = RecordingSegmentCompletion()
        completion.resolve(.success(()))
        completion.resolve(.failure(CancellationError()))
        try await completion.wait(seconds: 0.01)
        XCTAssertFalse(completion.isWaiting)
    }
    @MainActor
    func testCompletionAfterWaitResumesAndCancelsTimeout() async throws {
        let completion = RecordingSegmentCompletion()
        let waiter = Task { try await completion.wait(seconds: 0.1) }
        await Task.yield()
        XCTAssertTrue(completion.isWaiting)
        completion.resolve(.success(()))
        try await waiter.value
        try await Task.sleep(for: .milliseconds(150))
        try await completion.wait(seconds: 0.01)
    }
    @MainActor
    func testCancellationAndTimeoutReleaseWaiterAndPreserveFirstResult() async throws {
        let cancelled = RecordingSegmentCompletion()
        let waiter = Task { try await cancelled.wait(seconds: 10) }
        await Task.yield(); waiter.cancel()
        do { try await waiter.value; XCTFail("Cancelled wait succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(cancelled.isWaiting)
        let timedOut = RecordingSegmentCompletion()
        do { try await timedOut.wait(seconds: 0.01); XCTFail("Missing delegate did not time out") } catch { XCTAssertEqual(error.localizedDescription, L10n.text("录屏文件结束写入超时。已完成的分段保留在本机。")) }
        timedOut.resolve(.success(()))
        do { try await timedOut.wait(); XCTFail("Late callback replaced timeout") } catch { XCTAssertEqual(error.localizedDescription, L10n.text("录屏文件结束写入超时。已完成的分段保留在本机。")) }
    }
}
