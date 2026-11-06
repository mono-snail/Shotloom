import Foundation

/// The watchdog runs independently of the device queue. Completing a waiter does
/// not claim that a blocked OS call has stopped or that its file lease is free.
final class CameraOperationWait<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var watchdog: DispatchWorkItem?
    var pending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    @discardableResult func resolve(_ value: Result<Value, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let waiter = continuation, timer = watchdog
        continuation = nil; watchdog = nil; lock.unlock()
        timer?.cancel(); waiter?.resume(with: value); return true
    }
    func value(timeout: Double, message: String, onAbandon: @escaping @Sendable () -> Void = {}, start: () -> Void) async throws -> Value {
        try await withTaskCancellationHandler(operation: {
            return try await withCheckedThrowingContinuation { waiter in
                lock.lock()
                if let result { lock.unlock(); waiter.resume(with: result); start(); return }
                continuation = waiter
                let timer = DispatchWorkItem { [weak self] in
                    if self?.resolve(.failure(CaptureError.message(message))) == true { onAbandon() }
                }
                watchdog = timer; lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                start()
            }
        }, onCancel: { if self.resolve(.failure(CancellationError())) { onAbandon() } })
    }
}

/// Bound submissions while an OS call is still executing, even after its waiter
/// timed out. The permit is released by actual queue work, never by a timeout.
final class CameraOperationPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    func enter() -> Bool { lock.lock(); defer { lock.unlock() }; if active { return false }; active = true; return true }
    func leave() { lock.lock(); active = false; lock.unlock() }
}
