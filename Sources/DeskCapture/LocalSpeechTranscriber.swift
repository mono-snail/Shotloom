import Foundation
import AVFoundation
import Darwin

/// Locates the fixed, bundled processing helpers. Upstream executable names and
/// license notices are preserved; an installed app never falls back to the cwd.
enum LocalProcessingRuntime {
    enum Component {
        case transcription, voiceProcessing

        var resourcePath: String {
            switch self {
            case .transcription: return "SpeechRuntime/whisper-cli"
            case .voiceProcessing: return "VoiceRuntime/desk-voice"
            }
        }

        var developmentPath: String {
            switch self {
            case .transcription: return "build/whisper-runtime/bin/whisper-cli"
            case .voiceProcessing: return "build/voice-runtime/desk-voice"
            }
        }
    }

    static func executable(for component: Component) -> URL? {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(component.resourcePath),
           FileManager.default.isExecutableFile(atPath: resource.path) { return resource }
        if Bundle.main.bundleURL.pathExtension != "app" {
            let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(component.developmentPath)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

enum LocalSpeechTranscriber {
    static var runtime: URL? { LocalProcessingRuntime.executable(for: .transcription) }
    static func transcribe(_ video: URL, tier: LocalSpeechTier, language: String, models: LocalSpeechModels = .shared) async throws -> [CaptionSegment] {
        guard ["auto", "zh", "en", "ja", "ko", "fr", "de", "es"].contains(language), let executable = runtime else { throw CaptureError.message(L10n.text("本地字幕引擎尚未随应用正确安装，或语言参数无效。")) }
        let model = try await models.acquire(tier)
        do {
            let result = try await run(video, model: model, executable: executable, language: language)
            await models.release(tier); return result
        } catch { await models.release(tier); throw error }
    }
    private static func run(_ video: URL, model: URL, executable: URL, language: String) async throws -> [CaptionSegment] {
        let asset = AVURLAsset(url: video), duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 3600, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw CaptureError.message(L10n.text("本地模型转写支持有音轨的60分钟以内视频。")) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-local-speech-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let compressed = root.appendingPathComponent("audio.m4a"), wav = root.appendingPathComponent("audio.wav"), output = root.appendingPathComponent("transcript")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw CaptureError.message(L10n.text("无法准备本地转写音轨。")) }
        try await VideoExport.export(export, to: compressed, as: .m4a)
        let worker = Task.detached(priority: .userInitiated) {
            try convert(compressed, to: wav)
            try execute(executable, arguments: ["-m", model.path, "-f", wav.path, "-l", language, "-oj", "-of", output.path, "-np", "-t", "4"], directory: root)
            try Task.checkCancellation()
            let json = output.appendingPathExtension("json"), size = try json.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_000_000 else { throw CaptureError.message(L10n.text("字幕结果超过预算，未替换现有字幕。")) }
            return try parse(Data(contentsOf: json), duration: duration)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func parse(_ data: Data, duration: Double) throws -> [CaptionSegment] {
        struct Output: Decodable { struct Row: Decodable { struct Offsets: Decodable { let from: Double; let to: Double }; let offsets: Offsets; let text: String }; let transcription: [Row] }
        guard data.count <= 16_000_000, duration.isFinite, duration > 0 else { throw CaptureError.message(L10n.text("字幕结果无效。")) }
        let result = try JSONDecoder().decode(Output.self, from: data)
        guard result.transcription.count <= 20_000 else { throw CaptureError.message(L10n.text("字幕片段超过预算。")) }
        var rows: [CaptionSegment] = []
        for row in result.transcription {
            try Task.checkCancellation()
            let start = row.offsets.from / 1000, end = min(duration, row.offsets.to / 1000)
            let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard start.isFinite, end.isFinite, start >= 0, end > start, text.utf8.count <= 64_000 else { throw CaptureError.message(L10n.text("模型输出字幕时间或文本无效，未替换现有字幕。")) }
            if !text.isEmpty { rows.append(.init(start: start, end: end, text: text)) }
        }
        return rows.sorted { $0.start < $1.start }
    }
    static func convert(_ input: URL, to output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768),
              let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw CaptureError.message(L10n.text("无法转换本地转写音频。")) }
        let writer = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var ended = false
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: destination, error: &conversionError) { requested, state in
                // AAC readers may throw eofErr when asked to read again after
                // their final partial buffer. The converter can request more
                // input while draining its own tail; signal EOF before that
                // extra read instead of discarding a fully decoded track.
                if ended || file.framePosition >= file.length {
                    ended = true; state.pointee = .endOfStream; return nil
                }
                do {
                    let remaining = AVAudioFrameCount(min(Int64(source.frameCapacity), file.length - file.framePosition))
                    try file.read(into: source, frameCount: min(requested, remaining))
                    if source.frameLength == 0 { ended = true; state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData; return source
                } catch { readError = error; state.pointee = .noDataNow; return nil }
            }
            if let error = readError ?? conversionError { throw error }
            if destination.frameLength > 0 { try writer.write(from: destination) }
            if status == .endOfStream { break }
            if status == .error || (destination.frameLength == 0 && status == .inputRanDry) { throw CaptureError.message(L10n.text("音轨转换未完成。")) }
        }
    }
    static func execute(_ executable: URL, arguments: [String], directory: URL, timeout: Double = 1800, context: String = L10n.text("本地字幕引擎")) throws {
        let process = Process(), logURL = directory.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = log; process.standardError = log; process.standardInput = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": directory.path]
        try Task.checkCancellation(); try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  (try logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw CaptureError.message(L10n.text("\(context)超时或日志超过预算，未提交输出。")) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try Task.checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw CaptureError.message(L10n.text("\(context)未完成处理；原视频和已有文件保持。")) }
    }
}
