import Foundation
import AVFoundation
import ScreenCaptureKit

/// All mutable state and AVAssetWriter calls are confined to queue. Movie
/// fragments preserve a readable prefix after interruption; no second encoder.
final class FragmentedScreenWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Result: Sendable {
        let duration: Double
        let videoFrames: Int
        let droppedVideo: Int
        let droppedAudio: Int
        let sourceVideoFrames: Int
        let heldVideoFrames: Int
    }
    let queue = DispatchQueue(label: "com.deskcapture.fragment-writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private let fps: Int
    private let failure: @Sendable (Error) -> Void
    private var start: CMTime?
    private var startedDate: Date?
    private var lastVideo = CMTime.zero
    private var lastTimes: [Int: CMTime] = [:]
    private var videoFrames = 0, droppedVideo = 0, droppedAudio = 0
    private var sourceVideoFrames = 0, heldVideoFrames = 0
    private var finishing = false
    private var outcome: Swift.Result<Result, Error>?
    private var startWaiters: [CheckedContinuation<Date, Error>] = []
    private var finishWaiters: [CheckedContinuation<Result, Error>] = []
    private var reportedFailure = false
    private var lastVideoSample: CMSampleBuffer?
    private var heartbeat: DispatchSourceTimer?
    private var requestedEnd: CMTime?
    private var retainedLease: RecordingSessionLease?
    init(url: URL, width: Int, height: Int, fps: Int, systemAudio: Bool, microphone: Bool, lease: RecordingSessionLease? = nil, failure: @escaping @Sendable (Error) -> Void) throws {
        retainedLease = lease
        self.fps = fps; self.failure = failure
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(60_000_000, max(2_000_000, width * height * fps / 12)), AVVideoMaxKeyFrameIntervalDurationKey: 1, AVVideoAllowFrameReorderingKey: false]])
        video.expectsMediaDataInRealTime = true
        func track(channels: Int, title: String) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels * 64000])
            let name = AVMutableMetadataItem(); name.identifier = .commonIdentifierTitle; name.value = title as NSString
            input.metadata = [name]
            input.expectsMediaDataInRealTime = true; return input
        }
        audio = systemAudio ? track(channels: 2, title: "DeskCapture System Audio") : nil
        self.microphone = microphone ? track(channels: 1, title: "DeskCapture Microphone") : nil
        super.init()
        guard writer.canAdd(video) else { throw CaptureError.message(L10n.text("无法建立分片视频轨道。")) }; writer.add(video)
        for input in [audio, self.microphone].compactMap({ $0 }) {
            guard writer.canAdd(input) else { throw CaptureError.message(L10n.text("无法建立分片声音轨道。")) }; writer.add(input)
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool { append(sampleBuffer, type: type) }
    }
    // Synthetic buffers exercise the actual writer; ScreenCaptureKit attachment
    // validation remains exclusive to the real stream callback.
    private struct DiagnosticSample: @unchecked Sendable { let value: CMSampleBuffer }
    // Caller transfers an immutable synthetic buffer and must not modify its pixels.
    func submitDiagnosticVideo(_ sample: CMSampleBuffer) async {
        let immutable = DiagnosticSample(value: sample)
        await withCheckedContinuation { continuation in queue.async {
            self.append(immutable.value, type: .screen, requireScreenAttachment: false); continuation.resume()
        } }
    }
    private func append(_ sample: CMSampleBuffer, type: SCStreamOutputType, requireScreenAttachment: Bool = true) {
        guard !finishing, outcome == nil, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { return }
        if type == .screen {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { return }
            if requireScreenAttachment {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            }
            if start == nil {
                guard writer.startWriting() else { fail(writer.error ?? CaptureError.message(L10n.text("无法开始分片写入。"))); return }
                writer.startSession(atSourceTime: time); start = time
                let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds - time.seconds
                let date = Date().addingTimeInterval(-(host.isFinite && host >= 0 && host < 1 ? host : 0)); startedDate = date
                startWaiters.forEach { $0.resume(returning: date) }; startWaiters = []
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.5, repeating: 0.5); timer.setEventHandler { [weak self] in self?.holdStaticFrame() }; heartbeat = timer; timer.resume()
            }
        }
        guard let start, time >= start else { return }
        let target: AVAssetWriterInput?
        switch type { case .screen: target = video; case .audio: target = audio; case .microphone: target = microphone; @unknown default: target = nil }
        guard let target else { return }
        let key = Int(type.rawValue)
        if type == .screen { lastVideoSample = sample }
        guard lastTimes[key].map({ time > $0 }) ?? true else { return }
        if type == .screen { sourceVideoFrames += 1 }
        guard target.isReadyForMoreMediaData else { if type == .screen { droppedVideo += 1 } else { droppedAudio += 1 }; return }
        guard target.append(sample) else { fail(writer.error ?? CaptureError.message(L10n.text("分片录制样本写入失败。"))); return }
        lastTimes[key] = time
        if type == .screen { videoFrames += 1; lastVideo = time }
    }
    private func fail(_ error: Error) {
        guard !reportedFailure else { return }; reportedFailure = true
        startWaiters.forEach { $0.resume(throwing: error) }; startWaiters = []; failure(error)
        complete(.failure(error))
    }
    private func holdStaticFrame() {
        guard !finishing, outcome == nil, let start, let sample = lastVideoSample, writer.status == .writing, video.isReadyForMoreMediaData else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: 0.2, preferredTimescale: 600)
        guard time.seconds - start.seconds < 1_000_000, (time - lastVideo).seconds > 0.4 else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copied: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copied) == noErr, let copied else { return }
        if video.append(copied) { lastVideo = time; lastTimes[Int(SCStreamOutputType.screen.rawValue)] = time; videoFrames += 1; heldVideoFrames += 1 }
        else { fail(writer.error ?? CaptureError.message(L10n.text("静止画面续写失败。"))) }
    }
    func waitForStart() async throws -> Date {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in queue.async {
                if let outcome = self.outcome { switch outcome { case .failure(let error): continuation.resume(throwing: error); case .success: continuation.resume(throwing: CaptureError.message(L10n.text("录制已经结束。"))) }; return }
                if let date = self.startedDate { continuation.resume(returning: date); return }
                self.startWaiters.append(continuation)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    guard self.startedDate == nil, !self.startWaiters.isEmpty else { return }
                    self.fail(CaptureError.message(L10n.text("10秒内没有完整屏幕帧，未继续录制。")))
                    self.beginFinish()
                }
            } }
        }, onCancel: { self.finishInBackground() })
    }
    func finish(at end: CMTime? = nil) async throws -> Result {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in queue.async {
                if let outcome = self.outcome { continuation.resume(with: outcome); return }
                self.requestedEnd = end; self.finishWaiters.append(continuation); self.beginFinish()
            } }
        }, onCancel: { self.finishInBackground() })
    }
    /// Finish rather than cancelWriting: cancellation must not delete the raw
    /// movie's recoverable fragments. The capture stream is stopped separately.
    func finishInBackground() { queue.async { self.beginFinish() } }
    private func beginFinish() {
        guard !finishing, outcome == nil else { return }; finishing = true
        heartbeat?.cancel(); heartbeat = nil
        startWaiters.forEach { $0.resume(throwing: CancellationError()) }; startWaiters = []
        guard let start, writer.status == .writing else { retainedLease = nil; complete(.failure(writer.error ?? CaptureError.message(L10n.text("录制未产生可用视频帧，原分片保留。")))); return }
        let proposed = requestedEnd ?? CMClockGetTime(CMClockGetHostTimeClock())
        let end = proposed.isNumeric && proposed > start && (proposed - start).seconds < 1_000_000 ? proposed : lastVideo + CMTime(value: 1, timescale: CMTimeScale(fps))
        if let sample = lastVideoSample, (end - lastVideo).seconds > 1.1 / Double(fps) {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while !video.isReadyForMoreMediaData && writer.status == .writing && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if video.isReadyForMoreMediaData {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)), presentationTimeStamp: end - CMTime(value: 1, timescale: CMTimeScale(fps)), decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy { if video.append(copy) { videoFrames += 1; heldVideoFrames += 1 } }
            }
        }
        writer.endSession(atSourceTime: end)
        video.markAsFinished(); audio?.markAsFinished(); microphone?.markAsFinished()
        let result = Result(duration: max(0, (end - start).seconds), videoFrames: videoFrames, droppedVideo: droppedVideo, droppedAudio: droppedAudio,
                            sourceVideoFrames: sourceVideoFrames, heldVideoFrames: heldVideoFrames)
        writer.finishWriting { self.queue.async {
            self.retainedLease = nil
            if self.writer.status == .completed { self.complete(.success(result)) }
            else { self.complete(.failure(self.writer.error ?? CaptureError.message(L10n.text("分片文件收尾失败，已写入内容保留。")))) }
        } }
        queue.asyncAfter(deadline: .now() + 15) {
            guard self.outcome == nil else { return }
            self.complete(.failure(CaptureError.message(L10n.text("分片文件收尾超过15秒；保留文件，未删除恢复数据。"))))
        }
    }
    private func complete(_ result: Swift.Result<Result, Error>) {
        guard outcome == nil else { return }; outcome = result
        heartbeat?.cancel(); heartbeat = nil; lastVideoSample = nil
        finishWaiters.forEach { $0.resume(with: result) }; finishWaiters = []
    }
}
