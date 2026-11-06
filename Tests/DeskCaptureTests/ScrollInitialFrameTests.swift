import XCTest
@testable import DeskCapture

@MainActor
final class ScrollInitialFrameTests: XCTestCase {
    func testASettledLatestFrameBecomesTheAnchorInsteadOfTheFirstTransitionalFrame() async throws {
        let opening = WorkflowCorpus.texture(width: 120, height: 80, seed: 17)
        let settled = WorkflowCorpus.texture(width: 120, height: 80, seed: 23)
        let sequence = [opening, settled, settled]
        var index = 0
        let result = try await ScrollInitialFrame.acquire(interval: .zero) {
            defer { index += 1 }
            return sequence[index]
        }
        XCTAssertEqual(result.samples, 3)
        XCTAssertEqual(result.image.dataProvider!.data! as Data, settled.dataProvider!.data! as Data)
    }

    func testContinuousLoadingExhaustsItsBudgetWithoutReturningAnAnchor() async throws {
        let a = WorkflowCorpus.texture(width: 120, height: 80, seed: 17)
        let b = WorkflowCorpus.texture(width: 120, height: 80, seed: 23)
        var calls = 0
        do {
            _ = try await ScrollInitialFrame.acquire(maximumSamples: 4, interval: .zero) {
                defer { calls += 1 }
                return calls % 2 == 0 ? a : b
            }
            XCTFail("Changing frames were committed")
        } catch {
            XCTAssertEqual(calls, 4)
        }
    }

    func testInvalidBudgetAndChangedPixelDimensionsRejectBeforeCommit() async throws {
        let a = WorkflowCorpus.texture(width: 120, height: 80, seed: 17)
        let b = WorkflowCorpus.texture(width: 121, height: 80, seed: 23)
        var calls = 0
        do {
            _ = try await ScrollInitialFrame.acquire(maximumSamples: 1, interval: .zero) { calls += 1; return a }
            XCTFail("Invalid budget accepted")
        } catch { XCTAssertEqual(calls, 0) }
        do {
            _ = try await ScrollInitialFrame.acquire(interval: .zero) {
                defer { calls += 1 }
                return calls == 0 ? a : b
            }
            XCTFail("Changed geometry accepted")
        } catch { XCTAssertEqual(calls, 2) }
    }

    func testCancellationDuringSettlingDoesNotCaptureOrCommitAnotherFrame() async throws {
        let image = WorkflowCorpus.texture(width: 120, height: 80, seed: 17)
        var calls = 0
        let work = Task {
            try await ScrollInitialFrame.acquire(interval: .seconds(2)) { calls += 1; return image }
        }
        while calls == 0 { await Task.yield() }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled settling delivered an anchor") }
        catch is CancellationError { XCTAssertEqual(calls, 1) }
    }
}
