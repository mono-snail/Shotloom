import XCTest
@testable import DeskCapture

final class CameraOperationWaitTests: XCTestCase {
    func testWatchdogReturnsWhileDeviceQueueIsBlocked() async throws {
        let queue = DispatchQueue(label: "DeskCapture.test.blocked-camera"), release = DispatchSemaphore(value: 0)
        queue.async { _ = release.wait(timeout: .now() + 3) }
        let waiting = CameraOperationWait<Int>(), permit = CameraOperationPermit()
        XCTAssertTrue(permit.enter())
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await waiting.value(timeout: 0.05, message: "injected hung driver", start: {
                queue.async { defer { permit.leave() }; if waiting.pending { waiting.resolve(.success(1)) } }
            })
            XCTFail("Blocked queue returned a value")
        } catch { XCTAssertTrue(error.localizedDescription.contains("injected hung driver")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.8)
        XCTAssertFalse(permit.enter(), "Timed-out work still owns its queue permit")
        release.signal()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        XCTAssertTrue(permit.enter()); permit.leave()
    }
    func testCancellationBeforeContinuationInstallationStillRunsCleanupSubmission() async throws {
        let waiting = CameraOperationWait<Int>(), queue = DispatchQueue(label: "DeskCapture.test.camera-cancel"), permit = CameraOperationPermit()
        XCTAssertTrue(permit.enter())
        waiting.resolve(.failure(CancellationError()))
        do {
            _ = try await waiting.value(timeout: 1, message: "should not timeout", start: {
                queue.async { defer { permit.leave() }; if waiting.pending { waiting.resolve(.success(2)) } }
            })
            XCTFail("Early cancellation was ignored")
        } catch { XCTAssertTrue(error is CancellationError) }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        XCTAssertTrue(permit.enter()); permit.leave()
    }
    func testTaskCancellationReturnsBeforeQueueUnblocksAndLateResultIsRejected() async throws {
        let queue = DispatchQueue(label: "DeskCapture.test.camera-late"), release = DispatchSemaphore(value: 0)
        queue.async { _ = release.wait(timeout: .now() + 3) }
        let waiting = CameraOperationWait<Int>()
        let task = Task {
            try await waiting.value(timeout: 2, message: "late", start: { queue.async { waiting.resolve(.success(3)) } })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(waiting.resolve(.success(4)))
        release.signal()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func testOnlyOneConcurrentResultWins() async throws {
        let waiting = CameraOperationWait<Int>()
        let value = Task { try await waiting.value(timeout: 2, message: "no winner", start: {}) }
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<100 { group.addTask { waiting.resolve(.success(index)) } }
            var count = 0; for await won in group { if won { count += 1 } }; return count
        }
        XCTAssertEqual(wins, 1)
        let selected = try await value.value; XCTAssertTrue((0..<100).contains(selected))
    }
}
