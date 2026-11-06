import Foundation
import AVFoundation

struct VideoSourceFrameIndex: Sendable {
    let times: [Double]
    let duration: Double
    static func build(asset: AVAsset, track: AVAssetTrack, duration: Double) async throws -> Self {
        guard duration.isFinite, duration > 0 else { throw CaptureError.message(L10n.text("源帧索引时长无效。")) }
        let mappings = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping)
        let worker = Task.detached(priority: .userInitiated) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CaptureError.message(L10n.text("无法读取源帧时间，未开始遮盖导出。")) }
            reader.add(output); guard reader.startReading() else { throw reader.error ?? CaptureError.message(L10n.text("无法索引源帧。")) }
            defer { reader.cancelReading() }
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard times.count < 1_000_000, ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message(L10n.text("源帧索引超预算，未导出。")) }
                // Reader emits zero-sample edit/discontinuity markers, not frames.
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                guard CMSampleBufferGetNumSamples(sample) == 1 else { throw CaptureError.message(L10n.text("源帧索引超预算或含不支持的打包时间格式，未导出。")) }
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard time.isFinite else { throw CaptureError.message(L10n.text("源视频帧时间无效。")) }
                times.append(time)
            }
            guard reader.status == .completed, !times.isEmpty else { throw reader.error ?? CaptureError.message(L10n.text("源帧索引不完整。")) }
            let projected = try project(times, mappings: mappings, duration: duration, deadline: deadline)
            try Task.checkCancellation(); return Self(times: projected, duration: duration)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    /// Compressed reader timestamps are media times. Edit-list source ranges
    /// select/preroll those samples; their target ranges define display time.
    static func project(_ raw: [Double], mappings: [CMTimeMapping], duration: Double,
                        deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 90) throws -> [Double] {
        guard !raw.isEmpty, raw.count <= 1_000_000, mappings.count <= 20_000, !mappings.isEmpty,
              raw.allSatisfy(\.isFinite) else { throw CaptureError.message(L10n.text("源帧时间或编辑列表超预算，未导出。")) }
        let ordered = raw.sorted()
        var media: [Double] = []
        for time in ordered { if media.last != time { media.append(time) } }
        func firstAtLeast(_ time: Double) -> Int {
            var lo = 0, hi = media.count
            while lo < hi { let mid = (lo + hi) / 2; if media[mid] < time { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        var result: [Double] = []
        for mapping in mappings {
            try Task.checkCancellation()
            let source = mapping.source, target = mapping.target
            let start = source.start.seconds, end = source.end.seconds
            let targetStart = target.start.seconds, targetLength = target.duration.seconds
            guard [start, end, targetStart, targetLength].allSatisfy(\.isFinite), end > start, targetLength > 0,
                  targetStart >= -0.001, target.end.seconds <= duration + 0.001 else { throw CaptureError.message(L10n.text("视频编辑列表时间范围无效，未导出。")) }
            var index = max(0, firstAtLeast(start) - 1)
            while index < media.count, media[index] < end {
                try Task.checkCancellation()
                guard result.count < 1_000_000, ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message(L10n.text("源帧编辑映射超预算，未导出。")) }
                let next = index + 1 < media.count ? media[index + 1] : end
                if min(next, end) > start {
                    let clipped = max(start, media[index])
                    let time = targetStart + (clipped - start) * targetLength / (end - start)
                    result.append(min(duration, max(0, time)))
                }
                index += 1
            }
        }
        result.sort()
        var unique: [Double] = []
        for time in result { if unique.last != time { unique.append(time) } }
        guard !unique.isEmpty else { throw CaptureError.message(L10n.text("没有可显示的源帧时间，未导出。")) }
        return unique
    }
    /// Extend to the complete source sample intervals intersecting this window.
    /// VFR holds can be much longer than one nominal frame duration.
    func covering(_ window: ClosedRange<Double>) -> ClosedRange<Double> {
        guard !times.isEmpty else { return window }
        func after(_ time: Double) -> Int {
            var lo = 0, hi = times.count
            while lo < hi { let mid = (lo + hi) / 2; if times[mid] <= time { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        let lower = times[max(0, after(window.lowerBound) - 1)]
        let upperIndex = after(window.upperBound), upper = upperIndex < times.count ? times[upperIndex] : duration
        return min(lower, window.lowerBound)...max(upper, window.upperBound)
    }
}
