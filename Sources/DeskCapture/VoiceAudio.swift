import Foundation
import AVFoundation
import SwiftUI

struct VoiceAudioOptions: Codable, Equatable {
    var bypass = false
    var neural = false
    var wet = 0.75
    var loudness = false
    var targetLUFS = -16.0
    var ceilingDBTP = -1.0
    var musicDucking = false
    var duckDB = -12.0
    var attack = 0.1
    var release = 0.5
    var hold = 0.3
    var active: Bool { !bypass && (neural || loudness || musicDucking) }
    func validate() throws {
        guard [wet, targetLUFS, ceilingDBTP, duckDB, attack, release, hold].allSatisfy(\.isFinite),
              (0...1).contains(wet), (-30 ... -10).contains(targetLUFS), (-6 ... -1).contains(ceilingDBTP),
              (-30...0).contains(duckDB), (0.05...1).contains(attack), (0.1...3).contains(release), (0...2).contains(hold) else { throw CaptureError.message(L10n.text("人声/响度/音乐压低参数超出范围。")) }
    }
}
struct VoiceAudioReport: Codable {
    let frames: Int
    let sampleRate: Int
    let inputLUFS: Double?
    let outputLUFS: Double?
    let truePeak: Double
    let gainDB: Double
    let peakLimited: Bool
    let vad: [Double]
    func validate() throws {
        guard sampleRate == 48000, frames > 0, frames <= 3600 * 48000, truePeak.isFinite, truePeak >= 0,
              gainDB.isFinite, inputLUFS?.isFinite != false, outputLUFS?.isFinite != false,
              vad.count == (frames + 4799) / 4800, vad.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CaptureError.message(L10n.text("音频模型测量结果无效。")) }
    }
    func ducking(options: VoiceAudioOptions) -> [Float] {
        guard options.musicDucking, !options.bypass else { return [] }
        let low = pow(10, options.duckDB / 20)
        var gain = 1.0, held = 0.0, result: [Float] = [1]
        for probability in vad {
            if probability >= 0.6 { held = options.hold + 0.1 } else { held = max(0, held - 0.1) }
            let target = held > 0 ? low : 1
            let amount = min(1, 0.1 / (target < gain ? options.attack : options.release))
            gain += (target - gain) * amount; result.append(Float(gain))
        }
        return result
    }
}

enum VoiceAudioProcessor {
    static var runtime: URL? { LocalProcessingRuntime.executable(for: .voiceProcessing) }
    static func processFile(_ input: URL, to output: URL, options: VoiceAudioOptions) throws -> VoiceAudioReport {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-voice-convert-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm = root.appendingPathComponent("input.f32")
        try RecordingStorageBudget.require(root, bytes: 5_000_000_000)
        try convert(input, to: pcm)
        return try processRawPCM(pcm, to: output, options: options)
    }
    static func measureRawPCM(_ pcm: URL) throws -> VoiceAudioReport {
        try Task.checkCancellation()
        guard let executable = runtime else { throw CaptureError.message(L10n.text("本地音频计量引擎未打包。")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-meter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("report.json")
        try LocalSpeechTranscriber.execute(executable, arguments: [pcm.path, root.appendingPathComponent("unused.f32").path, report.path, "0", "measure", "-16", "-1", "0"], directory: root, context: "成片音频计量")
        guard (try report.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw CaptureError.message(L10n.text("计量报告过大。")) }
        let value = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: report)); try value.validate(); return value
    }
    static func processRawPCM(_ pcm: URL, to output: URL, options: VoiceAudioOptions) throws -> VoiceAudioReport {
        try options.validate(); try Task.checkCancellation()
        guard let executable = runtime else { throw CaptureError.message(L10n.text("本地人声引擎未正确打包，未替换现有输出。")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-voice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= 5_000_000_000 else { throw CaptureError.message(L10n.text("人声处理需要至少5GB临时空间，未开始处理。")) }
        let processed = root.appendingPathComponent("output.f32"), reportURL = root.appendingPathComponent("report.json")
        try LocalSpeechTranscriber.execute(executable, arguments: [pcm.path, processed.path, reportURL.path,
            String(options.neural && !options.bypass ? options.wet : 0), options.loudness && !options.bypass ? "1" : "0",
            String(options.targetLUFS), String(options.ceilingDBTP), options.musicDucking && !options.bypass ? "1" : "0"], directory: root, context: L10n.text("本地音频引擎"))
        guard (try reportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw CaptureError.message(L10n.text("音频报告超过预算。")) }
        let report = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: reportURL)); try report.validate()
        guard (try processed.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == report.frames * 8 else { throw CaptureError.message(L10n.text("音频处理帧数不匹配。")) }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-voice-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: stage) }
        try wrap(processed, to: stage); try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: output) }
        if let directory = ProcessInfo.processInfo.environment["DESKCAPTURE_PERFORMANCE_REPORT_DIR"] {
            do {
                let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONEncoder().encode(report).write(to: root.appendingPathComponent("r39-audio-\(UUID()).json"), options: .atomic)
            } catch { NSLog("DeskCapture audio report unavailable: %@", error.localizedDescription) }
        }
        return report
    }
    private static func convert(_ input: URL, to output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        guard file.processingFormat.sampleRate > 0, Double(file.length) / file.processingFormat.sampleRate <= 3600,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536),
              let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw CaptureError.message(L10n.text("人声处理支持最长60分钟的可读音频。")) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        var ended = false, frames = 0
        while true {
            try Task.checkCancellation(); var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: destination, error: &conversionError) { requested, state in
                if ended { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: source, frameCount: min(requested, source.frameCapacity))
                    if source.frameLength == 0 { ended = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData; return source
                } catch { readError = error; state.pointee = .noDataNow; return nil }
            }
            if let error = readError ?? conversionError { throw error }
            if destination.frameLength > 0 {
                let buffer = destination.audioBufferList.pointee.mBuffers
                guard let bytes = buffer.mData, buffer.mDataByteSize == destination.frameLength * 8 else { throw CaptureError.message(L10n.text("PCM通道格式不匹配。")) }
                frames += Int(destination.frameLength); guard frames <= 3600 * 48000 else { throw CaptureError.message(L10n.text("音频超过60分钟。")) }
                try handle.write(contentsOf: Data(bytes: bytes, count: Int(buffer.mDataByteSize)))
            }
            if status == .endOfStream { break }
            if status == .error || (destination.frameLength == 0 && status == .inputRanDry) { throw CaptureError.message(L10n.text("人声音轨转换未完成。")) }
        }
    }
    static func wrap(_ input: URL, to output: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw CaptureError.message(L10n.text("无法封装音轨。")) }
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
        while let data = try handle.read(upToCount: 4096 * 8), !data.isEmpty {
            try Task.checkCancellation(); guard data.count % 8 == 0 else { throw CaptureError.message(L10n.text("处理音轨不完整。")) }
            buffer.frameLength = AVAudioFrameCount(data.count / 8)
            guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { throw CaptureError.message(L10n.text("无法写入音轨。")) }
            data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: data.count); try file.write(from: buffer)
        }
    }
}

struct VoiceAudioEditor: View {
    @Binding var options: VoiceAudioOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoControlGrid { Toggle(L10n.text("原声对照"), isOn: $options.bypass) }
            if !options.bypass {
                VideoInspectorGroup(L10n.text("人声增强")) {
                    Toggle(L10n.text("增强人声"), isOn: $options.neural)
                    if options.neural {
                        InspectorSlider(title: L10n.text("混合比例"), value: $options.wet, range: 0...1, scale: 100, unit: "%")
                    }
                }
                VideoInspectorGroup(L10n.text("响度")) {
                    Toggle(L10n.text("统一响度"), isOn: $options.loudness)
                    if options.loudness {
                        InspectorSlider(title: L10n.text("目标响度"), value: $options.targetLUFS, range: -30 ... -10, unit: " LUFS")
                        InspectorSlider(title: L10n.text("峰值上限"), value: $options.ceilingDBTP, range: -6 ... -1, unit: " dBTP")
                    }
                }
                VideoInspectorGroup(L10n.text("音乐避让")) {
                    Toggle(L10n.text("讲话时降低音乐"), isOn: $options.musicDucking)
                    if options.musicDucking {
                        InspectorSlider(title: L10n.text("降低幅度"), value: $options.duckDB, range: -30...0, unit: " dB")
                        InspectorSlider(title: L10n.text("响应时间"), value: $options.attack, range: 0.05...1, unit: L10n.text(" 秒"), decimals: 2)
                        InspectorSlider(title: L10n.text("恢复时间"), value: $options.release, range: 0.1...3, unit: L10n.text(" 秒"), decimals: 1)
                        InspectorSlider(title: L10n.text("保持时间"), value: $options.hold, range: 0...2, unit: L10n.text(" 秒"), decimals: 1)
                    }
                }
            }
        }
    }
}
