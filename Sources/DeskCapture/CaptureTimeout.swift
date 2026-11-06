import Foundation

@MainActor
private final class CaptureRace<T> {
    var continuation: CheckedContinuation<T, Error>?
    var timeout: Task<Void, Never>?
    var operation: Task<Void, Never>?
    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        operation?.cancel(); operation = nil
        continuation.resume(with: result)
    }
}

@MainActor
func captureWithTimeout<T>(_ seconds: Double = 10, operation: @escaping @MainActor () async throws -> T) async throws -> T {
    let race = CaptureRace<T>()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        race.continuation = continuation
        race.timeout = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { race.finish(.failure(CaptureError.message(L10n.text("屏幕捕获没有及时响应。请确认系统权限授予的是当前 DeskCapture，并重启 App 后重试。")))) }
        }
        race.operation = Task {
            guard !Task.isCancelled else { race.finish(.failure(CancellationError())); return }
            do { race.finish(.success(try await operation())) }
            catch { race.finish(.failure(CaptureEngine.normalizedCaptureError(error))) }
        }
      }
    } onCancel: {
        Task { @MainActor in race.finish(.failure(CancellationError())) }
    }
}
