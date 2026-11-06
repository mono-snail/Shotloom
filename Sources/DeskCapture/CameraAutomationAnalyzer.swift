import AVFoundation
import Vision
import CoreImage

enum CameraAutomationAnalyzer {
    static func analyze(source: URL, camera: URL, duration: Double, options: CameraAutomationOptions) async throws -> CameraAutomationAnalysis {
        try options.validate(duration: duration)
        guard options.active else { return .init() }
        let worker = Task.detached(priority: .userInitiated) {
            let started = ProcessInfo.processInfo.systemUptime
            var result = CameraAutomationAnalysis()
            if options.hideWhenQuiet {
                let asset = AVURLAsset(url: source), tracks = try await asset.loadTracks(withMediaType: .audio)
                if !tracks.isEmpty {
                    let bins = try energy(asset: asset, tracks: tracks, duration: duration, deadline: started + 180)
                    result.audioAvailable = true
                    result.quiet = CameraAutomationAnalysis.quietIntervals(bins, options: options)
                }
            }
            if options.followFace {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: camera))
                generator.maximumSize = CGSize(width: 512, height: 512); generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
                defer { generator.cancelAllCGImageGeneration() }
                var tracker = StableFaceTracker()
                for index in 0..<Int(ceil(duration * 2)) {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - started < 180 else { throw CaptureError.message(L10n.text("摄像头自动分析超过180秒预算，未导出；可关闭自动功能保留手动布局。")) }
                    let time = Double(index) / 2
                    var faces: [CGRect] = []
                    do {
                        let frame = try await withTaskCancellationHandler(operation: { try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image }, onCancel: { generator.cancelAllCGImageGeneration() })
                        try Task.checkCancellation()
                        faces = autoreleasepool {
                            let request = VNDetectFaceRectanglesRequest()
                            guard (try? VNImageRequestHandler(cgImage: frame).perform([request])) != nil else { return [] }
                            return request.results?.filter { $0.confidence >= 0.6 }.map(\.boundingBox) ?? []
                        }
                    } catch { if Task.isCancelled { throw CancellationError() } }
                    if !faces.isEmpty { result.faceDetections += 1 }
                    result.faces.append(.init(time: time, center: tracker.update(faces, at: time)))
                }
            }
            try Task.checkCancellation(); return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    /// Read every original audio track separately; take the largest track energy,
    /// rather than allowing opposite-phase tracks to cancel into false silence.
    private static func energy(asset: AVAsset, tracks: [AVAssetTrack], duration: Double, deadline: Double) throws -> [Double?] {
        let count = Int(ceil(duration * 10)), rate = 16000.0
        var result = [Double?](repeating: nil, count: count)
        for track in tracks {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CaptureError.message(L10n.text("音轨无法用于静音能量分析。")) }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CaptureError.message(L10n.text("无法读取音轨。")) }
            defer { reader.cancelReading() }
            var squares = [Double](repeating: 0, count: count), samples = [Int](repeating: 0, count: count)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message(L10n.text("音轨自动分析超过180秒预算，尚未导出。")) }
                try autoreleasepool {
                    guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw CaptureError.message(L10n.text("音轨数据不可读，未判定为静音。")) }
                    let bytes = CMBlockBufferGetDataLength(buffer)
                    guard bytes > 0, bytes <= 4_000_000, bytes % 8 == 0 else { throw CaptureError.message(L10n.text("音轨PCM格式或分块超出预算。")) }
                    var values = [Float](repeating: 0, count: bytes / 4)
                    let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
                    guard status == kCMBlockBufferNoErr else { throw CaptureError.message(L10n.text("无法读取PCM块，未判定为静音。")) }
                    let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard start.isFinite else { throw CaptureError.message(L10n.text("音轨时间无效，未判定为静音。")) }
                    for frame in 0..<(values.count / 2) {
                        let bin = Int(floor((start + Double(frame) / rate) * 10))
                        guard bin >= 0, bin < count else { continue }
                        let a = Double(values[frame * 2]), b = Double(values[frame * 2 + 1])
                        guard a.isFinite, b.isFinite else { throw CaptureError.message(L10n.text("音轨含非有限采样，未判定为静音。")) }
                        squares[bin] += a * a + b * b; samples[bin] += 2
                    }
                }
            }
            guard reader.status == .completed else { throw reader.error ?? CaptureError.message(L10n.text("音轨分析未完成。")) }
            for index in 0..<count where samples[index] > 0 {
                let db = 10 * log10(max(1e-12, squares[index] / Double(samples[index])))
                result[index] = max(result[index] ?? -120, db)
            }
        }
        return result
    }
}
