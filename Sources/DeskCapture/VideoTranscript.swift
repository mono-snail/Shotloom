import Foundation
import AVFoundation
import Speech

struct CaptionSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var keep = true
}

enum VideoTranscript {
    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("captions.json") }
    static func load(_ video: URL) -> [CaptionSegment] {
        if RecordingEditStore.exists(video) { return (try? RecordingEditStore.load(video))?.captions ?? [] }
        guard let data = try? RecordingEditStore.sidecarData(url(for: video)) else { return [] }
        return ((try? JSONDecoder().decode([CaptionSegment].self, from: data)) ?? [])
            .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end < 1_000_000 }
            .sorted { $0.start < $1.start }
    }
    static func save(_ captions: [CaptionSegment], for video: URL) throws {
        if RecordingEditStore.exists(video) {
            let expected = try RecordingEditStore.fingerprint(video)
            guard var saved = try RecordingEditStore.load(video) else { throw CaptureError.message(L10n.text("字幕工程已移除，请重新打开。")) }
            saved.captions = captions
            _ = try RecordingEditStore.save(saved, for: video, expected: expected); return
        }
        try JSONEncoder().encode(captions).write(to: url(for: video), options: .atomic)
    }
    static func srt(_ captions: [CaptionSegment]) -> String {
        func time(_ value: Double) -> String {
            let ms = max(0, Int((value * 1000).rounded()))
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return captions.filter { $0.keep && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end < 1_000_000 }.enumerated().map { index, caption in
            "\(index + 1)\n\(time(caption.start)) --> \(time(caption.end))\n\(caption.text)\n"
        }.joined(separator: "\n")
    }
    static func parseSRT(_ text: String) throws -> [CaptionSegment] {
        func time(_ value: Substring) -> Double? {
            let components = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard components.count == 3, let hours = Double(components[0]), let minutes = Double(components[1]),
                  let seconds = Double(components[2].split(separator: " ").first ?? "") else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        }
        var result: [CaptionSegment] = []
        for block in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let range = lines[index].components(separatedBy: "-->")
            guard range.count == 2, let start = time(Substring(range[0])), let end = time(Substring(range[1])),
                  start.isFinite, end.isFinite, start >= 0, end > start, end < 1_000_000 else { continue }
            let content = lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { result.append(CaptionSegment(start: start, end: end, text: content)) }
        }
        guard !result.isEmpty else { throw CaptureError.message(L10n.text("没有找到有效的 SRT 字幕。")) }
        return result.sorted { $0.start < $1.start }
    }

    static var systemTranscriptionAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }
    static func transcribe(_ video: URL, localeIdentifier: String) async throws -> [CaptionSegment] {
        guard #available(macOS 26, *) else { throw CaptureError.message(L10n.text("系统转写需要 macOS 26；可选择本地模型引擎或导入SRT。")) }
        guard SpeechTranscriber.isAvailable else { throw CaptureError.message(L10n.text("此设备不支持系统转写；可选择本地模型引擎或导入SRT。")) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw CaptureError.message(L10n.text("此设备暂不支持所选语言的本地转写。"))
        }
        let asset = AVURLAsset(url: video)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw CaptureError.message(L10n.text("视频没有可用于转写的音轨。"))
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-speech-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: audio) }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptureError.message(L10n.text("视频没有可用于转写的音轨。"))
        }
        try await VideoExport.export(exporter, to: audio, as: .m4a)
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withTaskCancellationHandler {
            let results = Task { () throws -> [CaptionSegment] in
                var rows: [CaptionSegment] = []
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { rows.append(CaptionSegment(start: result.range.start.seconds, end: result.range.end.seconds, text: text)) }
                }
                return rows.sorted { $0.start < $1.start }
            }
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                let rows = try await results.value
                try Task.checkCancellation()
                return rows
            } catch { results.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        } onCancel: { Task { await analyzer.cancelAndFinishNow() } }
    }
}

struct VideoEditPlan {
    let ranges: [CMTimeRange]
    let rates: [Double]
    let captionIDs: [UUID?]
    var duration: Double { zip(ranges, rates).reduce(0) { $0 + $1.0.duration.seconds / $1.1 } }
    init(duration: Double, start: Double, end: Double, captions: [CaptionSegment], sections: [VideoSection] = []) throws {
        _ = try VideoTrimmer.range(start: start, end: end, duration: duration)
        let excluded = captions.filter { !$0.keep && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var cursor = start, kept: [CMTimeRange] = []
        func range(_ a: Double, _ b: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), duration: CMTime(seconds: b - a, preferredTimescale: 600))
        }
        for caption in excluded {
            let a = max(start, caption.start), b = min(end, caption.end)
            guard b > a else { continue }
            if a > cursor { kept.append(range(cursor, a)) }
            cursor = max(cursor, b)
        }
        if cursor < end { kept.append(range(cursor, end)) }
        if sections.isEmpty {
            guard kept.reduce(0, { $0 + $1.duration.seconds }) >= 0.1 else { throw CaptureError.message(L10n.text("删剪后没有足够的视频内容。")) }
            ranges = kept; rates = Array(repeating: 1, count: kept.count); captionIDs = Array(repeating: nil, count: kept.count)
        }
        else {
            var clipped: [CMTimeRange] = [], speeds: [Double] = [], ids: [UUID?] = []
            for section in sections where section.enabled {
                guard section.valid && section.end <= duration + 0.01 else { throw CaptureError.message(L10n.text("剪辑片段的时间或速度无效。")) }
                if let id = section.captionID, !captions.contains(where: { $0.id == id && $0.keep }) { continue }
                let available = section.captionID == nil ? kept : [range(start, end)]
                for item in available {
                    let a = max(section.start, item.start.seconds), b = min(section.end, item.end.seconds)
                    if b > a { clipped.append(range(a, b)); speeds.append(section.speed); ids.append(section.captionID) }
                }
            }
            guard zip(clipped, speeds).reduce(0.0, { $0 + $1.0.duration.seconds / $1.1 }) >= 0.1 else { throw CaptureError.message(L10n.text("没有保留的剪辑片段。")) }
            ranges = clipped; rates = speeds; captionIDs = ids
        }
    }
    func mapAll(_ time: Double) -> [Double] {
        var result: [Double] = [], offset = 0.0
        for (range, rate) in zip(ranges, rates) {
            if time >= range.start.seconds && time < range.end.seconds { result.append(offset + (time - range.start.seconds) / rate) }
            offset += range.duration.seconds / rate
        }
        return result
    }
    func map(_ time: Double) -> Double? { mapAll(time).first }
    func mappedCaptions(_ captions: [CaptionSegment]) -> [CaptionSegment] {
        var result: [CaptionSegment] = [], offset = 0.0
        for (index, pair) in zip(ranges, rates).enumerated() {
            let (range, rate) = pair
            for caption in captions where caption.keep && (captionIDs[index] == nil || captionIDs[index] == caption.id) {
                let a = max(range.start.seconds, caption.start), b = min(range.end.seconds, caption.end)
                if b > a { result.append(CaptionSegment(start: offset + (a - range.start.seconds) / rate, end: offset + (b - range.start.seconds) / rate, text: caption.text)) }
            }
            offset += range.duration.seconds / rate
        }
        return result
    }
}
