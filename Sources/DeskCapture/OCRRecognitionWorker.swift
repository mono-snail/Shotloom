import Foundation

/// Vision's synchronous request may finish after cancellation. Stop subsequent
/// passes and discard its result; cancellation does not imply native preemption.
enum OCRRecognitionWorker {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                let result = try await worker.value
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }, onCancel: { worker.cancel() })
    }
}
