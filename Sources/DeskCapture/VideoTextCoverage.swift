import Foundation
import AVFoundation
import Vision
import CoreGraphics

struct VideoTextCoverage: Sendable {
    struct Sample: Sendable { let time: Double; let boxes: [CGRect] }
    var samples: [Sample] = []
    func boxes(at time: Double) -> [CGRect] {
        guard time.isFinite, !samples.isEmpty else { return [] }
        var lo = 0, hi = samples.count
        while lo < hi { let mid = (lo + hi) / 2; if samples[mid].time <= time { lo = mid + 1 } else { hi = mid } }
        let before = max(0, lo - 1), after = min(samples.count - 1, lo)
        return samples[before].boxes + (before == after ? [] : samples[after].boxes)
    }
    static func detect(_ image: CGImage) throws -> [CGRect] {
        try Task.checkCancellation()
        let request = VNDetectTextRectanglesRequest(); request.reportCharacterBoxes = false
        try VNImageRequestHandler(cgImage: image).perform([request]); try Task.checkCancellation()
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var valid: [CGRect] = []
        for observation in request.results ?? [] {
            let rect = observation.boundingBox
            guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { continue }
            valid.append(rect)
        }
        valid.sort { a, b in a.width * a.height > b.width * b.height }
        var result: [CGRect] = []
        for rect in valid.prefix(160) {
            let clipped = rect.insetBy(dx: -0.005, dy: -0.005).intersection(unit)
            if !clipped.isNull && !clipped.isEmpty { result.append(clipped) }
        }
        return result
    }
    static func analyze(_ asset: AVAsset, duration: Double) async throws -> Self {
        guard duration.isFinite, duration > 0, duration <= 3600 else { throw CaptureError.message(L10n.text("文字区域抽样避让支持最长60分钟的源视频。")) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 768, height: 768)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        return try await withTaskCancellationHandler(operation: {
            let started = ProcessInfo.processInfo.systemUptime
            var result = Self()
            for index in 0...Int(ceil(duration / 2)) {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime - started < 180 else { throw CaptureError.message(L10n.text("文字区域分析超过180秒预算，未提交成片；可关闭抽样文字避让或缩短素材。")) }
                let requested = min(max(0, duration - 0.05), Double(index) * 2)
                let decoded = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 60000))
                let time = decoded.actualTime.seconds
                guard time.isFinite, time >= 0, time <= duration + 0.001 else { throw CaptureError.message(L10n.text("文字抽样画面时间无效。")) }
                if result.samples.last?.time == time { continue }
                let worker = Task.detached(priority: .utility) { try autoreleasepool { try detect(decoded.image) } }
                let boxes = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                result.samples.append(.init(time: time, boxes: boxes))
            }
            try Task.checkCancellation(); result.samples.sort { $0.time < $1.time }; return result
        }, onCancel: { generator.cancelAllCGImageGeneration() })
    }
}
