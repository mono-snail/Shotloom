import AVFoundation

/// Timestamp measurements, separate from nominal frame rate. Static VFR holds
/// remain visible in the report rather than being mislabeled as steady 30fps.
struct RecordedFrameCadence {
    let frames: Int
    let timestampSpan: Double
    let averageFPS: Double
    let medianInterval: Double
    let p95Interval: Double
    let maximumInterval: Double
    var report: [String: Any] {
        ["frames": frames, "timestampSpanSeconds": timestampSpan, "averageFPS": averageFPS,
         "medianIntervalSeconds": medianInterval, "p95IntervalSeconds": p95Interval,
         "maximumIntervalSeconds": maximumInterval, "source": "edit-list projected unique presentation timestamps", "timestampsDeduplicated": true,
         "constantFrameRateProven": false]
    }
    static func measure(_ url: URL) async throws -> RecordedFrameCadence {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        // Keep the asset alive across asynchronous metadata and sample reads.
        defer { withExtendedLifetime(asset) {} }
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CaptureError.message(L10n.text("视频没有可测量的画面轨道。")) }
        // Reuse the production VFR index: it skips zero-sample edit markers and
        // maps media timestamps through edit lists into presentation time.
        let index = try await VideoSourceFrameIndex.build(asset: asset, track: track, duration: duration)
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var times = index.times
            guard times.count <= 300_000 else { throw CaptureError.message(L10n.text("视频帧数超过测量预算。")) }
            // Encoded B frames can arrive in decode order, not presentation order.
            times.sort()
            guard times.count >= 2, let first = times.first, let last = times.last, last > first else { throw CaptureError.message(L10n.text("视频帧数不足，无法测量间隔。")) }
            var intervals = zip(times, times.dropFirst()).map { pair in pair.1 - pair.0 }
            guard intervals.allSatisfy({ $0 > 0 }) else { throw CaptureError.message(L10n.text("视频展示时间索引无效。")) }
            intervals.sort()
            func percentile(_ fraction: Double) -> Double { intervals[max(0, min(intervals.count - 1, Int((Double(intervals.count) * fraction).rounded(.up)) - 1))] }
            return RecordedFrameCadence(frames: times.count, timestampSpan: last - first,
                averageFPS: Double(times.count - 1) / (last - first), medianInterval: percentile(0.5),
                p95Interval: percentile(0.95), maximumInterval: intervals.last!)
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        return result
    }
}
