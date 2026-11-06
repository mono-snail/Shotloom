import Foundation
import AVFoundation

struct FinalAudioMasterReport: Codable {
    let normalized: VoiceAudioReport
    let encodedAttempts: [VoiceAudioReport]
    let correctionDB: Double
    let ceilingDBTP: Double
}
enum FinalAudioMaster {
    static func acceptable(_ peak: Double, ceilingDBTP: Double) -> Bool {
        peak.isFinite && peak >= 0 && peak <= pow(10, ceilingDBTP / 20) * 1.00001
    }
    static func correctionDB(peak: Double, ceilingDBTP: Double) throws -> Double {
        guard peak.isFinite, peak > 0, ceilingDBTP.isFinite else { throw CaptureError.message(L10n.text("成片音频峰值计量无效。")) }
        return min(0, ceilingDBTP - 20 * log10(peak) - 0.25)
    }
    static func normalize(_ asset: AVAsset, mix: AVAudioMix?, duration: Double, to wave: URL, options: VoiceAudioOptions) async throws -> VoiceAudioReport {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let worker = Task.detached(priority: .userInitiated) {
            let pcm = wave.deletingLastPathComponent().appendingPathComponent("final-mix-\(UUID()).f32")
            defer { try? FileManager.default.removeItem(at: pcm) }
            try RecordingStorageBudget.require(wave.deletingLastPathComponent(), bytes: Int64(ceil(duration * 48000)) * 8 * 5 + 256_000_000)
            try AudioMixPCM.write(asset, tracks: tracks, mix: mix, duration: duration, to: pcm)
            var master = options; master.neural = false; master.musicDucking = false; master.loudness = true; master.bypass = false
            return try VoiceAudioProcessor.processRawPCM(pcm, to: wave, options: master)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func verifyAndCorrect(_ movie: URL, normalized: URL, report: VoiceAudioReport, options: VoiceAudioOptions, duration: Double, scratch: URL) async throws -> FinalAudioMasterReport {
        var gainDB = 0.0, attempts: [VoiceAudioReport] = []
        for index in 0..<4 {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: movie)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let worker = Task.detached(priority: .userInitiated) {
                let pcm = scratch.appendingPathComponent("encoded-meter-\(UUID()).f32")
                defer { try? FileManager.default.removeItem(at: pcm) }
                try AudioMixPCM.write(asset, tracks: tracks, mix: nil, duration: duration, to: pcm)
                return try VoiceAudioProcessor.measureRawPCM(pcm)
            }
            let measured = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            attempts.append(measured)
            if acceptable(measured.truePeak, ceilingDBTP: options.ceilingDBTP) {
                return .init(normalized: report, encodedAttempts: attempts, correctionDB: gainDB, ceilingDBTP: options.ceilingDBTP)
            }
            guard index < 3 else { throw CaptureError.message(L10n.text("成片AAC真峰值复测仍超限，未替换目标文件。")) }
            gainDB += try correctionDB(peak: measured.truePeak, ceilingDBTP: options.ceilingDBTP)
            try await replaceAudio(in: movie, from: normalized, gainDB: gainDB, duration: duration, scratch: scratch)
        }
        throw CaptureError.message(L10n.text("成片音频复测未完成。"))
    }
    private static func replaceAudio(in movie: URL, from wave: URL, gainDB: Double, duration: Double, scratch: URL) async throws {
        let original = AVURLAsset(url: movie), audio = AVURLAsset(url: wave)
        defer { withExtendedLifetime((original, audio)) {} }
        guard let audioTrack = try await audio.loadTracks(withMediaType: .audio).first,
              let audioExport = AVAssetExportSession(asset: audio, presetName: AVAssetExportPresetAppleM4A) else { throw CaptureError.message(L10n.text("无法创建成片峰值修正任务。")) }
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        parameters.setVolume(Float(pow(10, gainDB / 20)), at: .zero)
        let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; audioExport.audioMix = mix
        let length = CMTime(seconds: duration, preferredTimescale: 48000)
        audioExport.timeRange = .init(start: .zero, duration: length)
        let encoded = scratch.appendingPathComponent("corrected-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: encoded) }
        try await VideoExport.export(audioExport, to: encoded, as: .m4a)
        let encodedAsset = AVURLAsset(url: encoded), composition = AVMutableComposition()
        defer { withExtendedLifetime(encodedAsset) {} }
        guard let sourceVideo = try await original.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await encodedAsset.loadTracks(withMediaType: .audio).first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.message(L10n.text("无法封装峰值修正后的成片。")) }
        try await RecordingVideoTimeline.append(sourceVideo, sourceDuration: length, to: video, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let available = CMTimeRangeGetIntersection(.init(start: .zero, duration: length), otherRange: try await sourceAudio.load(.timeRange))
        guard available.duration > .zero else { throw CaptureError.message(L10n.text("峰值修正后的音轨为空。")) }
        try target.insertTimeRange(available, of: sourceAudio, at: available.start)
        guard let remux = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw CaptureError.message(L10n.text("无法提交峰值修正音轨。")) }
        remux.timeRange = .init(start: .zero, duration: length)
        try await VideoExport.export(remux, to: movie, as: .mp4)
    }
}

/// Lossless Float32 mix snapshot. Preserve timeline gaps and head/tail silence;
/// never use an AAC intermediate before checking a potentially overfull mix.
enum AudioMixPCM {
    static func write(_ asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix?, duration: Double, to output: URL) throws {
        guard duration.isFinite, duration > 0, duration <= 3600 else { throw CaptureError.message(L10n.text("成片音频计量支持最长60分钟。")) }
        let expected = Int64((duration * 48000).rounded()), reader = try AVAssetReader(asset: asset)
        guard !tracks.isEmpty else { throw CaptureError.message(L10n.text("成片没有可计量的音轨。")) }
        let stream = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        stream.audioMix = mix; stream.alwaysCopiesSampleData = false
        guard reader.canAdd(stream) else { throw CaptureError.message(L10n.text("无法读取成片浮点混音。")) }
        reader.add(stream); reader.timeRange = .init(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48000))
        guard reader.startReading() else { throw reader.error ?? CaptureError.message(L10n.text("浮点混音读取未启动。")) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CaptureError.message(L10n.text("无法创建混音快照。")) }
        let file = try FileHandle(forWritingTo: output); defer { try? file.close() }
        var written: Int64 = 0
        let zeros = Data(count: 8192 * 8)
        func silence(until target: Int64) throws {
            while written < target {
                try Task.checkCancellation()
                let count = min(Int64(8192), target - written)
                try file.write(contentsOf: zeros.prefix(Int(count) * 8)); written += count
            }
        }
        while let sample = stream.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite, let description = CMSampleBufferGetFormatDescription(sample),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mSampleRate == 48000, format.mChannelsPerFrame == 2, format.mBytesPerFrame == 8,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw CaptureError.message(L10n.text("成片浮点混音格式无效。")) }
            let count = Int64(CMSampleBufferGetNumSamples(sample)), start = Int64((pts * 48000).rounded())
            guard count >= 0, count <= 1_048_576, abs(pts) <= 3601, CMBlockBufferGetDataLength(block) == Int(count) * 8 else { throw CaptureError.message(L10n.text("混音样本大小或时间无效。")) }
            if start > written { try silence(until: min(start, expected)) }
            let skip = max(0, written - start), available = min(max(0, count - skip), expected - written)
            guard available > 0 else { continue }
            var data = Data(count: Int(available) * 8)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: Int(skip) * 8, dataLength: Int(available) * 8, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw CaptureError.message(L10n.text("混音样本复制失败。")) }
            try file.write(contentsOf: data); written += available
        }
        guard reader.status == .completed else { throw reader.error ?? CaptureError.message(L10n.text("浮点混音读取未完成。")) }
        try silence(until: expected); try file.synchronize(); try Task.checkCancellation()
    }
}
