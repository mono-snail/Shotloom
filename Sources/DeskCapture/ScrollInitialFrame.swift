import AppKit

@MainActor
enum ScrollInitialFrame {
    struct Result {
        let image: CGImage
        let samples: Int
    }

    static func acquire(maximumSamples: Int = 12, interval: Duration = .milliseconds(180),
                        capture: () async throws -> CGImage) async throws -> Result {
        guard (2...20).contains(maximumSamples), interval >= .zero else {
            throw CaptureError.message(L10n.text("长图起始画面采样预算无效。"))
        }
        try Task.checkCancellation()
        var previous = try await capture()
        try Task.checkCancellation()
        let width = previous.width, height = previous.height
        for sample in 2...maximumSamples {
            try await Task.sleep(for: interval)
            try Task.checkCancellation()
            let next = try await capture()
            try Task.checkCancellation()
            guard next.width == width, next.height == height else {
                throw CaptureError.message(L10n.text("起始画面的像素尺寸改变，请重新选择长图区域。"))
            }
            let a = previous
            let comparison = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return ScrollFrameStability.compare(a, next)
            }
            let stability = try await withTaskCancellationHandler(operation: {
                try await comparison.value
            }, onCancel: { comparison.cancel() })
            try Task.checkCancellation()
            if stability.stable { return Result(image: next, samples: sample) }
            previous = next
        }
        throw CaptureError.message(L10n.text("起始画面仍在加载或大范围变化，请等待稳定后重新开始长图。"))
    }
}
