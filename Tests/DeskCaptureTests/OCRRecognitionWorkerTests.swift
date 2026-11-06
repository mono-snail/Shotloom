import XCTest
import AppKit
@testable import DeskCapture

final class OCRRecognitionWorkerTests: XCTestCase {
    func testCancelledEntryPointsRejectWork() async throws {
        let image = WorkflowCorpus.texture(width: 20, height: 20, seed: 42)
        for destination in [CaptureDestination.text, .code, .qr] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await CaptureEngine.extract(image, destination: destination)
            }
            do {
                _ = try await task.value
                XCTFail("Cancelled \(destination) must not return recognized content")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationDuringNativeWorkRejectsLateResult() async {
        let started = expectation(description: "Background recognition started")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await OCRRecognitionWorker.run {
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
                return "late recognition"
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled native result must be discarded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellationPreventsSecondRecognitionPass() async {
        let started = expectation(description: "First language pass started")
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await OCRRecognitionWorker.run {
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw FixtureError.timeout }
                try Task.checkCancellation()
                XCTFail("Second language pass must not start after cancellation")
                return "second pass"
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUncancelledResultAndErrorArePreserved() async throws {
        let value = try await OCRRecognitionWorker.run { "unchanged text" }
        XCTAssertEqual(value, "unchanged text")
        do {
            let _: String = try await OCRRecognitionWorker.run { throw FixtureError.expected }
            XCTFail("Recognition errors must propagate")
        } catch FixtureError.expected {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private enum FixtureError: Error { case timeout, expected }
}
