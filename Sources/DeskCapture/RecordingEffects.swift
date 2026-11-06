import AppKit
import AVFoundation
import CoreImage
import CoreText

struct RecordedInteraction: Codable {
    enum Kind: String, Codable { case pointer, click, shortcut }
    var time: Double
    var x: Double
    var y: Double
    var kind: Kind
    var label: String?
}

struct RecordingInteractions: Codable {
    var version = 1
    var smoothCursor: Bool
    var events: [RecordedInteraction]
    var recordedFPS: Int? = nil
    var editableCursorSource: String? = nil
    var audioSources: [String]? = nil
    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("interactions.json") }
    static func load(_ video: URL) -> RecordingInteractions? {
        let source = url(for: video)
        guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_000_000,
              let data = try? Data(contentsOf: source),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1, value.events.count <= 1_000_000 else { return nil }
        return value
    }
}

struct RecordingEffectsOptions: Codable, Equatable {
    var clicks = true
    var shortcuts = true
    var smartZoom = true
    var zoom = 1.65
    var background = true
    var padding = 0.055
    var style: BeautifyStyle = .aurora
    var layout: VideoCanvasLayout = .original
    var fillsCanvas = false
    var cornerRadius = 0.025
    var captions: [CaptionSegment] = []
    var burnCaptions = true
    var lenses: [RecordingLens] = []
    var audio = RecordingAudioOptions()
    var camera = CameraOverlayOptions()
    var cameraLayouts: [CameraLayoutCue]? = nil
    var cameraAutomation: CameraAutomationOptions? = nil
    var optics: RecordingOpticsOptions? = nil
    var cursor: RecordingCursorOptions? = nil
    var reframing: VideoReframingOptions? = nil
    var quality: VideoQualityOptions? = nil
    var privacy: [VideoPrivacyCue]? = nil
    var maximumDimension = 3840
    var outputFPS: Int? = nil
    var edit: VideoAdvancedEdit? = nil
}

enum VideoCanvasLayout: String, CaseIterable, Identifiable, Codable {
    case original, landscape, square, portrait
    var id: String { rawValue }
    var title: String { switch self { case .original: L10n.text("原比例"); case .landscape: "16:9"; case .square: "1:1"; case .portrait: "9:16" } }
    func size(source: CGSize, limit: Int = 3840) -> CGSize {
        let edge = min(CGFloat(limit), max(source.width, source.height))
        let result: CGSize
        switch self {
        case .original: result = CGSize(width: source.width * min(1, edge / max(source.width, source.height)), height: source.height * min(1, edge / max(source.width, source.height)))
        case .landscape: result = CGSize(width: edge, height: edge * 9 / 16)
        case .square: result = CGSize(width: edge, height: edge)
        case .portrait: result = CGSize(width: edge * 9 / 16, height: edge)
        }
        return CGSize(width: max(2, (result.width / 2).rounded(.down) * 2),
                      height: max(2, (result.height / 2).rounded(.down) * 2))
    }
}

enum RecordingMotion {
    static func pointer(at time: Double, events: [RecordedInteraction]) -> CGPoint? {
        guard !events.isEmpty else { return nil }
        var lower = 0, upper = events.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if events[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        let next = events[min(lower, events.count - 1)]
        let previous = events[max(0, lower - 1)]
        let interval = next.time - previous.time
        let t = interval > 0 ? min(1, max(0, (time - previous.time) / interval)) : 0
        let eased = t * t * (3 - 2 * t)
        return CGPoint(x: previous.x + (next.x - previous.x) * eased,
                       y: previous.y + (next.y - previous.y) * eased)
    }
    static func zoom(at time: Double, clicks: [RecordedInteraction], maximum: Double, easing: RecordingEasing = .smooth) -> (Double, CGPoint) {
        // A click attracts attention briefly; overlapping clicks extend the
        // focus without a discontinuous camera jump.
        var amount = 0.0, weight = 0.0, x = 0.0, y = 0.0
        for click in clicks where time >= click.time - 0.35 && time <= click.time + 2.5 {
            let age = time - click.time
            let envelope: Double
            if age < 0 { envelope = (age + 0.35) / 0.35 }
            else if age < 1.5 { envelope = 1 }
            else { envelope = (2.5 - age) }
            let smooth = max(0, min(1, envelope))
            let a = easing.value(smooth)
            amount = max(amount, a); weight += a; x += click.x * a; y += click.y * a
        }
        return (1 + (maximum - 1) * amount, weight > 0 ? CGPoint(x: x / weight, y: y / weight) : CGPoint(x: 0.5, y: 0.5))
    }
}

enum RecordingEffectsExporter {
    private static let enhancementGate = HistoryWriteGate()
    static func export(_ source: URL, to output: URL, options: RecordingEffectsOptions,
                       start: Double = 0, end: Double? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        _ = try await prepare(source, output: output, options: options, start: start, end: end, progress: progress)
    }

    /// Build the same full-length composition used by export, without encoding a preview movie.
    static func playback(_ source: URL, options: RecordingEffectsOptions, start: Double, end: Double) async throws -> RecordingEffectsPlayback {
        guard let playback = try await prepare(source, output: nil, options: options, start: start, end: end, progress: { _ in }) else {
            throw CaptureError.message(L10n.text("无法创建编辑预览。"))
        }
        return playback
    }

    private static func prepare(_ source: URL, output: URL?, options: RecordingEffectsOptions,
                                start: Double, end: Double?, progress: @escaping @Sendable (Double) -> Void) async throws -> RecordingEffectsPlayback? {
        let exportStarted = ProcessInfo.processInfo.systemUptime
        var playbackOwnsResources = false
        let opticsMetrics = RecordingOpticsMetrics()
        let cursorOptions = options.cursor ?? RecordingCursorOptions()
        let editableSource = cursorOptions.active ? try EditableCursorSource.resolve(source, metadata: RecordingInteractions.load(source)) : source
        let asset = AVURLAsset(url: editableSource)
        defer { withExtendedLifetime(asset) {} }
        let duration = try await asset.load(.duration)
        let optics = options.optics ?? RecordingOpticsOptions()
        try optics.validate()
        let quality = options.quality ?? VideoQualityOptions()
        try quality.validate()
        if quality.active { try await enhancementGate.acquire() }
        defer { if quality.active { Task { await enhancementGate.release() } } }
        try options.audio.validate()
        let reframing = options.reframing ?? VideoReframingOptions()
        try reframing.validate()
        try cursorOptions.validate(duration: duration.seconds)
        let cameraTimeline = try CameraLayoutTimeline(options.cameraLayouts ?? [], duration: duration.seconds)
        let automation = options.cameraAutomation ?? CameraAutomationOptions()
        try automation.validate(duration: duration.seconds)
        let privacy = try VideoPrivacyTimeline(options.privacy ?? [], duration: duration.seconds)
        guard [options.camera.x, options.camera.y, options.camera.width].allSatisfy(\.isFinite),
              (0...1).contains(options.camera.x), (0...1).contains(options.camera.y), (0.1...0.45).contains(options.camera.width) else { throw CaptureError.message(L10n.text("摄像头位置或大小无效。")) }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.message(L10n.text("录屏缺少视频画面。"))
        }
        let sourceTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let sourceSize = CGRect(origin: .zero, size: naturalSize).applying(sourceTransform).standardized.size
        let outputSize = options.layout.size(source: sourceSize, limit: min(3840, max(320, options.maximumDimension)))
        let estimatedMiB = try quality.estimatedMiB(source: sourceSize, output: outputSize, opticalSamples: optics.motionBlur ? optics.samples * (optics.cameraMotionBlur == true && options.camera.enabled ? optics.samples : 1) : 0)
        if quality.active {
            let formats = try await track.load(.formatDescriptions)
            for format in formats {
                let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
                let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                if VideoQualityFilter.isHDR(transfer) { throw CaptureError.message(L10n.text("当前画质增强只支持SDR素材；HDR请关闭增强后导出并检查色彩。")) }
            }
        }
        let qualityFilter = try VideoQualityFilter(options: quality)
        let sourceFrameIndex = privacy.cues.contains(where: { $0.kind == .opaque && $0.target != .camera }) ? try await VideoSourceFrameIndex.build(asset: asset, track: track, duration: duration.seconds) : VideoSourceFrameIndex(times: [], duration: duration.seconds)
        let renderContext: CIContext? = quality.active ? CIContext(options: [.cacheIntermediates: false, .memoryTarget: quality.memoryMiB / 2, .name: "DeskCapture video quality"]) : nil
        defer { renderContext?.clearCaches() }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.message(L10n.text("无法创建视频效果轨道。"))
        }
        let plan = try VideoEditPlan(duration: duration.seconds, start: start, end: end ?? duration.seconds, captions: options.captions, sections: options.edit?.sections ?? [])
        var cursor = CMTime.zero
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
        let destinationAudio = sourceAudio.map { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        for (range, rate) in zip(plan.ranges, plan.rates) {
            try await RecordingVideoTimeline.append(track, sourceDuration: range.duration, to: video, at: cursor, sourceStart: range.start)
            for (index, audio) in sourceAudio.enumerated() {
                let available = CMTimeRangeGetIntersection(range, otherRange: try await audio.load(.timeRange))
                if available.duration > .zero {
                    try destinationAudio[index]?.insertTimeRange(available, of: audio, at: cursor + available.start - range.start)
                }
            }
            let editedDuration = CMTime(seconds: range.duration.seconds / rate, preferredTimescale: 600)
            if rate != 1 { composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: editedDuration) }
            cursor = cursor + editedDuration
        }
        let temporaryAudio = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-audio-\(UUID())", isDirectory: true)
        defer { if !playbackOwnsResources { try? FileManager.default.removeItem(at: temporaryAudio) } }
        var processedAudioAsset: AVURLAsset?
        var voiceReport: VoiceAudioReport?
        let finalMixOptions = options.audio.voice.flatMap { $0.loudness && !$0.bypass ? $0 : nil }
        var finalMasterReport: VoiceAudioReport?
        let normalizedMix = temporaryAudio.appendingPathComponent("normalized-mix.wav")
        defer { withExtendedLifetime(processedAudioAsset) {} }
        let sourceTrackIndices = Dictionary(uniqueKeysWithValues: destinationAudio.enumerated().compactMap { index, track in
            track.map { ($0.trackID, index) }
        })
        let sourceVolumes = sourceTrackIndices.mapValues { options.audio.sourceVolumes?[$0] ?? 1 }
        var audioMix: AVAudioMix? = RecordingAudioProcessor.mix(tracks: composition.tracks(withMediaType: .audio), options: options.audio,
                                                              duration: cursor.seconds, sourceVolumes: sourceVolumes)
        let sourceProcessing = options.audio.needsProcessing && (options.audio.normalize || options.audio.cleanup || options.audio.spectralReduction == true || options.audio.voice?.neural == true || options.audio.voice?.musicDucking == true)
        if sourceProcessing && !sourceAudio.isEmpty {
            try FileManager.default.createDirectory(at: temporaryAudio, withIntermediateDirectories: true)
            let mixed = temporaryAudio.appendingPathComponent("mixed.wav"), cleaned = temporaryAudio.appendingPathComponent("cleaned.wav")
            let sourceMix = RecordingAudioProcessor.mix(tracks: composition.tracks(withMediaType: .audio), options: RecordingAudioOptions(), duration: cursor.seconds, sourceVolumes: sourceVolumes)
            let audioDuration = cursor.seconds, snapshotAudioTracks = composition.tracks(withMediaType: .audio)
            let processing = Task.detached(priority: .userInitiated) { () throws -> VoiceAudioReport? in
                let pcm = temporaryAudio.appendingPathComponent("source-mix.f32")
                defer { try? FileManager.default.removeItem(at: pcm) }
                try AudioMixPCM.write(composition, tracks: snapshotAudioTracks, mix: sourceMix, duration: audioDuration, to: pcm)
                try VoiceAudioProcessor.wrap(pcm, to: mixed)
                if var voice = options.audio.voice, voice.active {
                    voice.loudness = false // Master after music, volume and fades are mixed.
                    if options.audio.normalize || options.audio.cleanup || options.audio.spectralReduction == true {
                        let filtered = temporaryAudio.appendingPathComponent("filtered.wav")
                        try RecordingAudioProcessor.processFile(mixed, to: filtered, options: options.audio)
                        return try VoiceAudioProcessor.processFile(filtered, to: cleaned, options: voice)
                    }
                    return try VoiceAudioProcessor.processFile(mixed, to: cleaned, options: voice)
                }
                try RecordingAudioProcessor.processFile(mixed, to: cleaned, options: options.audio); return nil
            }
            voiceReport = try await withTaskCancellationHandler { try await processing.value } onCancel: { processing.cancel() }
            try Task.checkCancellation()
            for old in composition.tracks(withMediaType: .audio) { composition.removeTrack(old) }
            let cleanedAsset = AVURLAsset(url: cleaned); processedAudioAsset = cleanedAsset
            if let cleanedTrack = try await cleanedAsset.loadTracks(withMediaType: .audio).first,
               let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let available = try await cleanedTrack.load(.timeRange)
                try target.insertTimeRange(CMTimeRange(start: available.start, duration: min(available.duration, cursor)), of: cleanedTrack, at: .zero)
            }
            audioMix = RecordingAudioProcessor.mix(tracks: composition.tracks(withMediaType: .audio), options: options.audio, duration: cursor.seconds)
        }
        let previewAudioTrackIDs = Set(composition.tracks(withMediaType: .audio).map(\.trackID))
        var musicAsset: AVURLAsset?
        defer { withExtendedLifetime(musicAsset) {} }
        if let edit = options.edit, let path = edit.musicPath {
            let music = AVURLAsset(url: URL(fileURLWithPath: path)); musicAsset = music
            guard let track = try await music.loadTracks(withMediaType: .audio).first,
                  let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.message(L10n.text("背景音乐没有音轨。")) }
            let available = try await track.load(.timeRange)
            guard available.duration.seconds > 0.1 else { throw CaptureError.message(L10n.text("背景音乐太短。")) }
            var position = CMTime.zero
            while position < cursor {
                try Task.checkCancellation()
                let length = min(available.duration, cursor - position)
                try output.insertTimeRange(CMTimeRange(start: available.start, duration: length), of: track, at: position)
                position = position + length
            }
            let parameters = AVMutableAudioMixInputParameters(track: output)
            let volume = min(1, max(0, edit.musicVolume)), fade = CMTime(seconds: min(1, cursor.seconds / 3), preferredTimescale: 600)
            let ducking = voiceReport?.ducking(options: options.audio.voice ?? .init()) ?? []
            if ducking.count > 1 {
                func gain(_ index: Int, _ time: Double) -> Float {
                    let fadeSeconds = max(0.001, fade.seconds)
                    return volume * ducking[index] * Float(min(1, max(0, time / fadeSeconds), max(0, (cursor.seconds - time) / fadeSeconds)))
                }
                for index in 0..<(ducking.count - 1) {
                    let a = Double(index) * 0.1, b = min(cursor.seconds, Double(index + 1) * 0.1)
                    guard b > a else { continue }
                    parameters.setVolumeRamp(fromStartVolume: gain(index, a), toEndVolume: gain(index + 1, b), timeRange: CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), duration: CMTime(seconds: b - a, preferredTimescale: 600)))
                }
            } else {
                parameters.setVolume(volume, at: .zero)
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: fade))
                parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: cursor - fade, duration: fade))
            }
            let mix = AVMutableAudioMix(); mix.inputParameters = (audioMix?.inputParameters ?? []) + [parameters]; audioMix = mix
        }
        if let master = finalMixOptions, !composition.tracks(withMediaType: .audio).isEmpty {
            try await Task.detached(priority: .utility) { try FileManager.default.createDirectory(at: temporaryAudio, withIntermediateDirectories: true) }.value
            finalMasterReport = try await FinalAudioMaster.normalize(composition, mix: audioMix, duration: cursor.seconds, to: normalizedMix, options: master)
            try Task.checkCancellation()
            for old in composition.tracks(withMediaType: .audio) { composition.removeTrack(old) }
            let normalizedAsset = AVURLAsset(url: normalizedMix); processedAudioAsset = normalizedAsset
            guard let source = try await normalizedAsset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.message(L10n.text("完整混音归一后没有可用音轨。")) }
            try target.insertTimeRange(.init(start: .zero, duration: min(cursor, try await normalizedAsset.load(.duration))), of: source, at: .zero)
            audioMix = nil // Requested volume/fades and music gain were already applied.
        }
        video.preferredTransform = sourceTransform
        let drawingFrames = RecordingDrawingTimeline.load(editableSource).map(RecordingDrawingCache.init)
        let metadata = RecordingInteractions.load(editableSource)
        let cursorTimeline = RecordingCursorTimeline(events: metadata?.events ?? [])
        let focusTimeline = VideoFocusTimeline(events: reframing.enabled && reframing.mode == .activity ? metadata?.events ?? [] : [], duration: reframing.enabled ? duration.seconds : 0)
        let events = (metadata?.events ?? []).flatMap { event -> [RecordedInteraction] in
            plan.mapAll(event.time).map { time in var mapped = event; mapped.time = time; return mapped }
        }.sorted { $0.time < $1.time }
        let clicks = events.filter { $0.kind == .click }, shortcuts = events.filter { $0.kind == .shortcut }
        let captions = plan.mappedCaptions(options.captions)
        let lenses = RecordingLens.mapped(options.lenses, plan: plan)
        let captionImages = CaptionImageCache()
        let cameraURL = RecordingCamera.url(for: source)
        if options.camera.enabled && (!cameraTimeline.cues.isEmpty || automation.active || privacy.cues.contains(where: { $0.target == .camera })) {
            guard FileManager.default.fileExists(atPath: cameraURL.path),
                  !(try await AVURLAsset(url: cameraURL).loadTracks(withMediaType: .video)).isEmpty else { throw CaptureError.message(L10n.text("摄像头布局及自动处理需要可读的摄像头素材。")) }
        }
        let cameraFrameIndex: VideoSourceFrameIndex
        if options.camera.enabled, FileManager.default.fileExists(atPath: cameraURL.path), privacy.cues.contains(where: { $0.kind == .opaque && $0.target != .screen }) {
            let cameraAsset = AVURLAsset(url: cameraURL)
            guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first else { throw CaptureError.message(L10n.text("无法索引摄像头帧，未导出遮盖视频。")) }
            let cameraDuration = try await cameraAsset.load(.duration).seconds
            cameraFrameIndex = try await VideoSourceFrameIndex.build(asset: cameraAsset, track: cameraTrack, duration: cameraDuration)
        } else { cameraFrameIndex = VideoSourceFrameIndex(times: [], duration: duration.seconds) }
        let cameraAnalysis = options.camera.enabled && automation.active ? try await CameraAutomationAnalyzer.analyze(source: source, camera: cameraURL, duration: duration.seconds, options: automation) : CameraAutomationAnalysis()
        let textCoverage = reframing.enabled && reframing.avoidCamera && !reframing.lockCamera && reframing.avoidText == true && options.camera.enabled && FileManager.default.fileExists(atPath: cameraURL.path)
            ? try await VideoTextCoverage.analyze(asset, duration: duration.seconds) : VideoTextCoverage()
        let cameraFrames = options.camera.enabled && FileManager.default.fileExists(atPath: cameraURL.path) ? CameraFrameCache(url: cameraURL, removeBackground: options.camera.shape == .cutout) : nil
        defer { if !playbackOwnsResources, let cameraFrames { Task { await cameraFrames.cancel() } } }
        let cameraCoverage = try await cameraFrames?.availableFrames()
        let cursorImage = makeCursor()
        let badges = Dictionary(uniqueKeysWithValues: Set(shortcuts.compactMap(\.label)).map { ($0, makeBadge($0)) })
        let nominalFPS = try await track.load(.nominalFrameRate)
        let renderFPS = Double(min(60, max(15, options.outputFPS ?? metadata?.recordedFPS ?? (nominalFPS > 45 ? 60 : 30))))
        let liveState = output == nil ? RecordingPreviewState(options: options, timeline: cameraTimeline) : nil
        let filterHandler: @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void = { request in
            autoreleasepool {
                let snapshot = liveState?.snapshot()
                let renderOptions = snapshot?.options ?? options
                let cameraTimeline = snapshot?.timeline ?? cameraTimeline
                let colors = renderOptions.style.colors
                let firstColor = CIColor(color: colors.first!.usingColorSpace(.deviceRGB)!)!
                let lastColor = CIColor(color: colors.last!.usingColorSpace(.deviceRGB)!)!
                let bounds = CGRect(origin: .zero, size: sourceSize)
                let canvas = CGRect(origin: .zero, size: outputSize)
                let time = request.compositionTime.seconds
                let privacyWindow = sourceFrameIndex.covering(VideoPrivacyTimeline.sourceWindow(outputTime: time, fps: renderFPS, plan: plan))
                let safe = reframing.enabled ? reframing.safeRect(canvas) : canvas
                var focalPoint = reframing.mode == .locked ? CGPoint(x: reframing.focusX, y: reframing.focusY) : focusTimeline.focus(at: sourceTime(time, plan: plan))
                var frame = request.sourceImage
                if let annotation = drawingFrames?.image(at: sourceTime(time, plan: plan), size: sourceSize) { frame = annotation.composited(over: frame) }
                if metadata?.smoothCursor == true, let point = cursorTimeline.point(at: sourceTime(time, plan: plan), options: cursorOptions) {
                    let size = max(18, bounds.width * 0.023)
                    let pointerImage = cursorImage.transformed(by: CGAffineTransform(scaleX: size / 48, y: size / 48))
                        .transformed(by: CGAffineTransform(translationX: point.x * bounds.width,
                                                          y: point.y * bounds.height - size))
                    frame = pointerImage.composited(over: frame)
                }
                if renderOptions.clicks {
                    for click in clicks where time >= click.time && time <= click.time + 0.6 {
                        let age = (time - click.time) / 0.6
                        let radius = max(14, bounds.width * 0.017) * (0.6 + age)
                        let center = CIVector(x: click.x * bounds.width, y: click.y * bounds.height)
                        let ring = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": center,
                            "inputRadius0": radius * 0.72, "inputRadius1": radius,
                            "inputColor0": CIColor(red: 0.2, green: 0.85, blue: 0.95, alpha: 0.22 * (1 - age)),
                            "inputColor1": CIColor(red: 0.2, green: 0.85, blue: 0.95, alpha: 0)])!.outputImage!
                        frame = ring.cropped(to: bounds).composited(over: frame)
                    }
                }
                frame = privacy.apply(frame.cropped(to: bounds), target: .screen, window: privacyWindow)
                if (renderOptions.smartZoom || !lenses.isEmpty) && !reframing.enabled {
                    let opticalStarted = ProcessInfo.processInfo.systemUptime
                    let transforms = RecordingOptics.transforms(at: time, fps: renderFPS, section: RecordingOptics.section(at: time, plan: plan), bounds: bounds, options: optics) { moment in
                        let automatic = renderOptions.smartZoom ? RecordingMotion.zoom(at: moment, clicks: clicks, maximum: renderOptions.zoom, easing: optics.easing) : (1.0, CGPoint(x: 0.5, y: 0.5))
                        return RecordingLens.motion(at: moment, lenses: lenses, easing: optics.easing) ?? automatic
                    }
                    frame = RecordingOptics.render(frame, bounds: bounds, transforms: transforms)
                    let automatic = renderOptions.smartZoom ? RecordingMotion.zoom(at: time, clicks: clicks, maximum: renderOptions.zoom, easing: optics.easing) : (1.0, CGPoint(x: 0.5, y: 0.5))
                    let motion = RecordingLens.motion(at: time, lenses: lenses, easing: optics.easing) ?? automatic
                    let focusPixel = CGPoint(x: focalPoint.x * bounds.width, y: focalPoint.y * bounds.height)
                        .applying(RecordingOptics.transform(zoom: motion.0, focus: motion.1, bounds: bounds))
                    focalPoint = CGPoint(x: min(1, max(0, focusPixel.x / bounds.width)), y: min(1, max(0, focusPixel.y / bounds.height)))
                    opticsMetrics.add(seconds: ProcessInfo.processInfo.systemUptime - opticalStarted, taps: transforms.count)
                }
                if renderOptions.background || outputSize != sourceSize || reframing.enabled {
                    let inset = renderOptions.background ? min(canvas.width, canvas.height) * renderOptions.padding : 0
                    let inner = VideoReframing.viewport(canvas: canvas, options: reframing, background: renderOptions.background, padding: renderOptions.padding, captions: renderOptions.burnCaptions && !captions.isEmpty)
                    let fill = reframing.enabled ? reframing.mode != .fitAll : renderOptions.fillsCanvas
                    let placement = VideoReframing.placement(source: bounds, viewport: inner, focus: focalPoint, fill: fill)
                    let scaled = frame.transformed(by: placement)
                    var background = renderOptions.background ? CIFilter(name: "CILinearGradient", parameters: [
                        "inputPoint0": CIVector(x: 0, y: canvas.height), "inputPoint1": CIVector(x: canvas.width, y: 0),
                        "inputColor0": firstColor, "inputColor1": lastColor])!.outputImage! : CIImage(color: .black)
                    let content = fill ? inner : scaled.extent.intersection(inner)
                    let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: content),
                        "inputRadius": renderOptions.background ? min(canvas.width, canvas.height) * renderOptions.cornerRadius : 0,
                        "inputColor": CIColor.white])!.outputImage!
                    if renderOptions.background {
                        let shadow = mask.transformed(by: CGAffineTransform(translationX: 0, y: -inset * 0.15))
                            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, inset * 0.4)])
                        background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: shadow])
                    }
                    frame = scaled.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background,
                                                                                  kCIInputMaskImageKey: mask]).cropped(to: canvas)
                }
                if quality.active {
                    do { frame = try qualityFilter.apply(frame.cropped(to: canvas)) }
                    catch { request.finish(with: error); return }
                }
                var overlays: [CIImage] = []
                var captionRect: CGRect?
                if renderOptions.burnCaptions, let caption = captions.last(where: { time >= $0.start && time < $0.end }) {
                    let image = captionImages.image(caption.text, width: reframing.enabled ? safe.width : canvas.width * 0.86)
                    if reframing.enabled {
                        let rect = VideoReframing.caption(image.extent.size, in: safe)
                        let scaled = image.transformed(by: CGAffineTransform(scaleX: rect.width / image.extent.width, y: rect.height / image.extent.height))
                        overlays.append(scaled.transformed(by: CGAffineTransform(translationX: rect.minX - scaled.extent.minX, y: rect.minY - scaled.extent.minY)))
                        captionRect = rect
                    } else {
                        overlays.append(image.transformed(by: CGAffineTransform(translationX: canvas.midX - image.extent.width / 2, y: max(12, canvas.height * 0.045))))
                    }
                }
                if renderOptions.shortcuts, let shortcut = shortcuts.last(where: { time >= $0.time && time < $0.time + 1.6 }),
                   let label = shortcut.label, let badge = badges[label] {
                    let scale = reframing.enabled ? min(max(0.75, canvas.width / 1600), safe.width / badge.extent.width, safe.height * 0.12 / badge.extent.height) : max(0.75, canvas.width / 1600)
                    let image = badge.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    overlays.append(image.transformed(by: CGAffineTransform(translationX: canvas.midX - image.extent.width / 2,
                                                                   y: reframing.enabled ? min(safe.maxY - image.extent.height, (captionRect?.maxY ?? safe.minY) + 8) : canvas.height * 0.055)))
                }
                let finishedFrame = frame.cropped(to: canvas)
                let finishedOverlays = overlays
                func completed(_ image: CIImage, window: ClosedRange<Double>? = nil) -> CIImage {
                    let overlaid = finishedOverlays.reduce(image) { $1.composited(over: $0) }.cropped(to: canvas)
                    return privacy.apply(overlaid, target: .canvas, window: window ?? privacyWindow)
                }
                if let cameraFrames {
                    Task {
                        let sourceMoment = sourceTime(time, plan: plan)
                        do {
                        let cameraSample = try await cameraFrames.sample(at: sourceMoment)
                        let cameraWindow = cameraFrameIndex.covering(min(privacyWindow.lowerBound, cameraSample?.time ?? sourceMoment)...max(privacyWindow.upperBound, cameraSample?.time ?? sourceMoment))
                        let result = cameraSample.map { sample -> CIImage in
                            let camera = privacy.apply(sample.image, target: .camera, window: cameraWindow)
                            if cameraTimeline.cues.isEmpty && !automation.active && !reframing.enabled { return CameraFrameCache.composite(camera, over: finishedFrame, canvas: canvas, options: renderOptions.camera) }
                            let visibility = cameraAnalysis.visibility(at: sourceMoment, options: automation)
                            if visibility <= 0 { return finishedFrame }
                            let reframed = cameraAnalysis.reframed(camera, at: sourceMoment, options: automation)
                            func layout(at editedMoment: Double) -> CameraLayoutPose {
                                let moment = sourceTime(editedMoment, plan: plan)
                                var pose = cameraTimeline.pose(at: moment, canvas: canvas.size, camera: reframed.extent.size, options: renderOptions.camera)
                                if reframing.enabled && reframing.avoidCamera && !reframing.lockCamera && cameraTimeline.permitsAutomaticPlacement(at: moment) {
                                    let viewport = VideoReframing.viewport(canvas: canvas, options: reframing, background: renderOptions.background, padding: renderOptions.padding, captions: renderOptions.burnCaptions && !captions.isEmpty)
                                    func target(_ outputMoment: Double) -> CameraLayoutPose {
                                        let sourceMoment = sourceTime(outputMoment, plan: plan)
                                        let focal = reframing.mode == .locked ? CGPoint(x: reframing.focusX, y: reframing.focusY) : focusTimeline.focus(at: sourceMoment)
                                        let placement = VideoReframing.placement(source: bounds, viewport: viewport, focus: focal, fill: reframing.mode != .fitAll)
                                        let focus = CGPoint(x: focal.x * bounds.width, y: focal.y * bounds.height).applying(placement)
                                        var regions = [CGRect(x: focus.x - canvas.width * 0.05, y: focus.y - canvas.height * 0.05, width: canvas.width * 0.1, height: canvas.height * 0.1)]
                                        if renderOptions.burnCaptions && !captions.isEmpty { regions.append(CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: safe.height * 0.3)) }
                                        if renderOptions.shortcuts && !shortcuts.isEmpty { regions.append(CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: safe.height * 0.42 + 8)) }
                                        regions += textCoverage.boxes(at: sourceMoment).map { box in
                                            CGRect(x: box.minX * bounds.width, y: box.minY * bounds.height, width: box.width * bounds.width, height: box.height * bounds.height).applying(placement).intersection(viewport)
                                        }.filter { !$0.isNull && !$0.isEmpty }
                                        let original = cameraTimeline.pose(at: sourceMoment, canvas: canvas.size, camera: reframed.extent.size, options: renderOptions.camera)
                                        return VideoReframing.avoidingCamera(original, canvas: canvas, safe: safe, protected: regions, locked: !cameraTimeline.permitsAutomaticPlacement(at: sourceMoment))
                                    }
                                    pose = VideoReframing.smoothAvoidingCamera(pose, at: editedMoment, section: RecordingOptics.section(at: editedMoment, plan: plan), canvas: canvas, safe: safe, enabled: reframing.smoothCamera != false, target: target)
                                }
                                let visibility = cameraAnalysis.visibility(at: moment, options: automation)
                                if visibility < 1 {
                                    let screenOnly = CameraLayoutPose(camera: pose.camera, cameraOpacity: 0, radius: pose.radius)
                                    pose = .blend(screenOnly, pose, visibility)
                                }
                                return pose
                            }
                            let poses = CameraMotionOptics.poses(at: time, fps: Double(renderFPS), section: RecordingOptics.section(at: time, plan: plan), canvas: canvas.size, options: optics, motion: layout)
                            return CameraMotionOptics.composite(reframed, screen: finishedFrame, canvas: canvas, poses: poses, options: renderOptions.camera)
                        } ?? finishedFrame
                        request.finish(with: completed(result, window: cameraWindow), context: renderContext)
                        } catch { request.finish(with: error) }
                    }
                } else { request.finish(with: completed(finishedFrame), context: renderContext) }
            }
        }
        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: filterHandler)
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(renderFPS))
        videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        try Task.checkCancellation()
        guard let output else {
            let renderer = RecordingPreviewComposition(asset: composition.copy() as! AVComposition, initial: videoComposition, audioMix: audioMix, sourceAudioTrackIDs: previewAudioTrackIDs, sourceTrackIndices: sourceTrackIndices, filter: filterHandler)
            let playback = await MainActor.run {
                let item = AVPlayerItem(asset: renderer.asset)
                item.videoComposition = renderer.initial; item.audioMix = renderer.audioMix
                return RecordingEffectsPlayback(item: item, plan: plan, camera: cameraFrames, temporaryAudio: temporaryAudio,
                                                state: liveState!, renderer: renderer, cameraCoverage: cameraCoverage)
            }
            playbackOwnsResources = true
            return playback
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError.message(L10n.text("无法创建成片导出任务。"))
        }
        exporter.videoComposition = videoComposition
        exporter.timeRange = CMTimeRange(start: .zero, duration: cursor)
        exporter.audioMix = audioMix
        if let master = finalMixOptions, let masterReport = finalMasterReport {
            let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-master-\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: stage) }
            try await VideoExport.export(exporter, to: stage, as: .mp4, progress: { progress(0.15 + $0 * 0.7) })
            let measured = try await FinalAudioMaster.verifyAndCorrect(stage, normalized: normalizedMix, report: masterReport, options: master, duration: cursor.seconds, scratch: temporaryAudio)
            let commit = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: output.path) {
                    guard (try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
                          (try output.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CaptureError.message(L10n.text("成片目标不是普通文件，未替换。")) }
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: stage)
                } else { try FileManager.default.moveItem(at: stage, to: output) }
            }
            try await withTaskCancellationHandler(operation: { try await commit.value }, onCancel: { commit.cancel() })
            progress(1)
            if let directory = ProcessInfo.processInfo.environment["DESKCAPTURE_PERFORMANCE_REPORT_DIR"] {
                await Task.detached(priority: .utility) {
                    do {
                        let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        try JSONEncoder().encode(measured).write(to: root.appendingPathComponent("r44-final-mix-\(UUID()).json"), options: .atomic)
                    } catch { NSLog("DeskCapture final audio report unavailable: %@", error.localizedDescription) }
                }.value
            }
        } else {
            try await VideoExport.export(exporter, to: output, as: .mp4, progress: { progress(0.15 + $0 * 0.85) })
        }
        await opticsMetrics.report(exportSeconds: ProcessInfo.processInfo.systemUptime - exportStarted, options: optics)
        await qualityFilter.report(exportSeconds: ProcessInfo.processInfo.systemUptime - exportStarted, estimatedMiB: estimatedMiB)
        return nil
    }

    static func sourceTime(_ time: Double, plan: VideoEditPlan) -> Double {
        var offset = 0.0
        for (range, rate) in zip(plan.ranges, plan.rates) {
            if time < offset + range.duration.seconds / rate { return range.start.seconds + (time - offset) * rate }
            offset += range.duration.seconds / rate
        }
        return plan.ranges.last?.end.seconds ?? time
    }
    private static func makeCursor() -> CIImage {
        let context = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let path = CGMutablePath(); path.move(to: CGPoint(x: 3, y: 44))
        for point in [CGPoint(x: 4, y: 7), CGPoint(x: 14, y: 18), CGPoint(x: 23, y: 2),
                      CGPoint(x: 30, y: 6), CGPoint(x: 22, y: 22), CGPoint(x: 38, y: 22)] { path.addLine(to: point) }
        path.closeSubpath(); context.addPath(path); context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(2); context.drawPath(using: .fillStroke)
        return CIImage(cgImage: context.makeImage()!)
    }
    private static func makeBadge(_ text: String) -> CIImage {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor]))
        let width = max(64, Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil))) + 32)
        let context = CGContext(data: nil, width: width, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: 48), cornerWidth: 13, cornerHeight: 13, transform: nil))
        context.fillPath(); context.textPosition = CGPoint(x: 16, y: 15); CTLineDraw(line, context)
        return CIImage(cgImage: context.makeImage()!)
    }
}

private final class CaptionImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CIImage] = [:]
    private var order: [String] = []
    func image(_ text: String, width maximumWidth: CGFloat) -> CIImage {
        lock.lock(); defer { lock.unlock() }
        let key = "\(Int(maximumWidth)):\(text)"
        if let image = images[key] { return image }
        let fontSize = max(18, min(48, maximumWidth * 0.026))
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(".AppleSystemUIFont" as CFString, fontSize, nil),
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor]
        let string = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(string)
        let width = max(80, min(maximumWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 32))
        let setter = CTFramesetterCreateWithAttributedString(string)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                    CGSize(width: width - 32, height: 10_000), nil)
        let height = min(fontSize * 5 + 24, max(fontSize + 24, measured.height + 24))
        let context = CGContext(data: nil, width: Int(ceil(width)), height: Int(ceil(height)), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.black.withAlphaComponent(0.76).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: 10, cornerHeight: 10, transform: nil)); context.fillPath()
        let path = CGPath(rect: CGRect(x: 16, y: 12, width: width - 32, height: height - 24), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        let image = CIImage(cgImage: context.makeImage()!)
        if order.count >= 12 { images.removeValue(forKey: order.removeFirst()) }
        order.append(key); images[key] = image; return image
    }
}
