import AppKit
import AVFoundation

struct RecordingLens: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var x = 0.5
    var y = 0.5
    var zoom = 2.0
    var valid: Bool { start.isFinite && end.isFinite && x.isFinite && y.isFinite && zoom.isFinite && start >= 0 && end > start && (0...1).contains(x) && (0...1).contains(y) && (1...4).contains(zoom) }
    static func motion(at time: Double, lenses: [Self], easing: RecordingEasing = .smooth) -> (Double, CGPoint)? {
        guard let lens = lenses.last(where: { $0.valid && time >= $0.start && time < $0.end }) else { return nil }
        let ramp = min(0.35, (lens.end - lens.start) / 3)
        let amount = min(1, min((time - lens.start) / ramp, (lens.end - time) / ramp))
        let eased = easing.value(amount)
        return (1 + (lens.zoom - 1) * eased, CGPoint(x: lens.x, y: lens.y))
    }
    static func mapped(_ lenses: [Self], plan: VideoEditPlan) -> [Self] {
        var output: [Self] = [], offset = 0.0
        for (range, rate) in zip(plan.ranges, plan.rates) {
            for lens in lenses where lens.valid {
                let a = max(range.start.seconds, lens.start), b = min(range.end.seconds, lens.end)
                if b > a { var adjusted = lens; adjusted.id = UUID(); adjusted.start = offset + (a - range.start.seconds) / rate; adjusted.end = offset + (b - range.start.seconds) / rate; output.append(adjusted) }
            }
            offset += range.duration.seconds / rate
        }
        return output
    }
}

struct RecordingStudioProject: Codable {
    var version = 1
    var lenses: [RecordingLens] = []
    var effects: RecordingEffectsOptions? = nil
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("studio.json") }
    static func load(_ video: URL) -> Self {
        if RecordingEditStore.exists(video) { return (try? RecordingEditStore.load(video))?.studio ?? Self() }
        guard let data = try? RecordingEditStore.sidecarData(url(for: video)), let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1 else { return Self() }
        return Self(lenses: saved.lenses.filter(\.valid), effects: saved.effects, trimStart: saved.trimStart, trimEnd: saved.trimEnd)
    }
    func save(_ video: URL) throws {
        try effects?.audio.validate()
        try effects?.quality?.validate()
        if let cues = effects?.privacy { _ = try VideoPrivacyTimeline(cues, duration: 1_000_000) }
        if RecordingEditStore.exists(video) {
            let expected = try RecordingEditStore.fingerprint(video)
            guard var saved = try RecordingEditStore.load(video) else { throw CaptureError.message(L10n.text("字幕工程已移除，请重新打开。")) }
            saved.studio = self
            _ = try RecordingEditStore.save(saved, for: video, expected: expected); return
        }
        try effects?.optics?.validate()
        try effects?.reframing?.validate()
        try effects?.cursor?.validate(duration: 1_000_000)
        if let cues = effects?.cameraLayouts { _ = try CameraLayoutTimeline(cues, duration: 1_000_000) }
        if let automation = effects?.cameraAutomation { try automation.validate(duration: 3600) }
        try JSONEncoder().encode(self).write(to: Self.url(for: video), options: .atomic)
    }
}

enum VideoExport {
    static func export(_ session: AVAssetExportSession, to output: URL, as type: AVFileType,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-\(UUID()).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: stage) }
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.export(to: stage, as: type)
            try Task.checkCancellation()
        } onCancel: { session.cancelExport() }
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: output) }
        progress(1)
    }
}

struct RecordingAudioOptions: Codable, Equatable {
    var volume: Float = 1
    var normalize = false
    var cleanup = false
    var fade = 0.0
    var spectralReduction: Bool? = nil
    var reductionStrength: Float? = nil
    var voice: VoiceAudioOptions? = nil
    var sourceVolumes: [Int: Float]? = nil
    var needsProcessing: Bool { voice?.bypass != true && (normalize || cleanup || spectralReduction == true || voice?.active == true) }
    func validate() throws {
        try voice?.validate()
        guard sourceVolumes.map({ $0.count <= 128 && $0.allSatisfy { (0..<128).contains($0.key) && $0.value.isFinite && (0...2).contains($0.value) } }) != false else {
            throw CaptureError.message(L10n.text("声音轨道音量无效。"))
        }
        guard volume.isFinite, (0...2).contains(volume), fade.isFinite, (0...10).contains(fade),
              reductionStrength.map({ $0.isFinite && (0...1).contains($0) }) != false,
              !(normalize && voice?.loudness == true) else { throw CaptureError.message(L10n.text("音频参数无效；峰值归一和积分响度归一请选择一种。")) }
    }
}

struct VoiceCleanupFilter {
    private var previousInput: [Float]
    private var previousOutput: [Float]
    private var envelope: Float = 0
    private var gain: Float = 1
    private let highPass: Float
    init(channels: Int, sampleRate: Double) {
        previousInput = Array(repeating: 0, count: channels); previousOutput = previousInput
        let rc = 1 / (2 * Double.pi * 80)
        highPass = Float(rc / (rc + 1 / sampleRate))
    }
    mutating func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in previousInput.indices {
                let input = channels[channel][frame]
                let output = highPass * (previousOutput[channel] + input - previousInput[channel])
                previousInput[channel] = input; previousOutput[channel] = output
                channels[channel][frame] = output; peak = max(peak, abs(output))
            }
            envelope += (peak > envelope ? 0.04 : 0.001) * (peak - envelope)
            let target: Float = envelope < 0.008 ? max(0.08, envelope / 0.008) : 1
            gain += (target > gain ? 0.04 : 0.001) * (target - gain)
            for channel in previousInput.indices { channels[channel][frame] *= gain }
        }
    }
}

enum RecordingAudioProcessor {
    static func mix(tracks: [AVAssetTrack], options: RecordingAudioOptions, duration: Double,
                    sourceVolumes: [CMPersistentTrackID: Float] = [:]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            let volume = min(2, max(0, options.volume)) * min(2, max(0, sourceVolumes[track.trackID] ?? 1))
            p.setVolume(volume, at: .zero)
            let fade = min(max(0, options.fade), duration / 2)
            if fade > 0 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: fade, preferredTimescale: 600)))
                p.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: CMTime(seconds: duration - fade, preferredTimescale: 600), duration: CMTime(seconds: fade, preferredTimescale: 600)))
            }
            return p
        }
        return mix
    }
    static func processFile(_ input: URL, to output: URL, options: RecordingAudioOptions) throws {
        try options.validate()
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096), format.commonFormat == .pcmFormatFloat32 else { throw CaptureError.message(L10n.text("无法读取浮点音频。")) }
        let outputSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let destination = try AVAudioFile(forWriting: output, settings: outputSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var filter = VoiceCleanupFilter(channels: Int(format.channelCount), sampleRate: format.sampleRate)
        let spectral = options.spectralReduction == true ? try SpectralNoiseReducer(channels: Int(format.channelCount), strength: options.reductionStrength ?? 0.75) : nil
        var latency = spectral == nil ? 0 : SpectralNoiseReducer.hop
        var written: AVAudioFramePosition = 0
        // A bounded two-pass stream: peak analysis never loads the full recording.
        var peak: Float = 0
        if options.normalize {
            while source.framePosition < source.length {
                try Task.checkCancellation(); try source.read(into: buffer)
                guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                for channel in 0..<Int(format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[channel][i])) }
                }
            }
            source.framePosition = 0
        }
        let gain: Float = options.normalize && peak > 0.0001 ? min(4, 0.89 / peak) : 1
        while source.framePosition < source.length || written < source.length {
            try Task.checkCancellation()
            let reading = source.framePosition < source.length
            if reading { try source.read(into: buffer) }
            else { buffer.frameLength = AVAudioFrameCount(SpectralNoiseReducer.hop); if let data = buffer.floatChannelData { for channel in 0..<Int(format.channelCount) { for i in 0..<SpectralNoiseReducer.hop { data[channel][i] = 0 } } } }
            guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let originalCount = Int(buffer.frameLength)
            if let spectral {
                let padded = ((originalCount + SpectralNoiseReducer.hop - 1) / SpectralNoiseReducer.hop) * SpectralNoiseReducer.hop
                for channel in 0..<Int(format.channelCount) { for i in originalCount..<padded { samples[channel][i] = 0 } }
                buffer.frameLength = AVAudioFrameCount(padded)
                if options.cleanup { filter.process(samples, frames: padded) }
                spectral.process(samples, frames: padded)
            } else if options.cleanup { filter.process(samples, frames: originalCount) }
            let skip = min(latency, Int(buffer.frameLength)); latency -= skip
            let count = min(Int(buffer.frameLength) - skip, Int(source.length - written))
            for channel in 0..<Int(format.channelCount) { for i in 0..<count { samples[channel][i] = max(-0.98, min(0.98, samples[channel][i + skip] * gain)) } }
            if count > 0 { buffer.frameLength = AVAudioFrameCount(count); try destination.write(from: buffer); written += AVAudioFramePosition(count) }
        }
    }
}
