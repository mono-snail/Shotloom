import Foundation

// A recording delegate may finish before the user requests pause/stop. Keep
// that result so installing a waiter later cannot lose the completion event.
@MainActor
final class RecordingSegmentCompletion {
    private(set) var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        let waiting = continuation; continuation = nil
        waiting?.resume(with: result)
    }
    func wait(seconds: Double = 15) async throws {
        try Task.checkCancellation()
        if let result { try result.get(); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting in
                continuation = waiting
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    resolve(.failure(CaptureError.message(L10n.text("录屏文件结束写入超时。已完成的分段保留在本机。"))))
                }
            }
        } onCancel: { Task { @MainActor in self.resolve(.failure(CancellationError())) } }
    }
}
