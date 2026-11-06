import AppKit
import ScreenCaptureKit
import AVFoundation
import Combine

enum RecordingState { case idle, preparing, recording, paused, finishing }

@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate {
    private let preferences: UserDefaults
    private var preferencesLoaded = false
    init(preferences: UserDefaults = AppPreferences.standard) {
        self.preferences = preferences
        super.init()
        systemAudio = preferences.object(forKey: "recordSystemAudio") as? Bool ?? true
        showsCursor = preferences.object(forKey: "recordCursor") as? Bool ?? true
        fps = preferences.integer(forKey: "recordFPS") == 60 ? 60 : 30
        captureInteractions = preferences.object(forKey: "recordInteractions") as? Bool ?? true
        captureShortcuts = preferences.bool(forKey: "recordShortcuts")
        smoothCursor = preferences.bool(forKey: "recordSmoothCursor")
        cameraEnabled = preferences.bool(forKey: "recordCamera")
        cameraDeviceID = preferences.string(forKey: "recordCameraDevice") ?? ""
        microphone = microphonePreference(camera: cameraEnabled)
        preferencesLoaded = true
        camera.setStoppedHandler { [weak self] event in
            Task { @MainActor in
                guard let self, event.unexpected, (self.state == .preparing || self.state == .recording || self.state == .paused), self.cameraActive,
                      event.file.deletingLastPathComponent() == self.directory,
                      event.file.lastPathComponent == self.sessionSegments.last?.camera else { return }
                self.cameraUnavailable = true
                self.cameraStopEvent = event
                if self.state == .paused { self.cameraActive = false; self.camera.shutdown() }
                self.warning = L10n.text("摄像头已停止输出，屏幕录制继续；已录摄像头素材保留，缺失区间留空。") + (event.message.map { L10n.text(" 原因：\($0)") } ?? "")
            }
        }
    }
    @Published private(set) var state: RecordingState = .idle { didSet { speakerNotes.recordingStateChanged(state) } }
    @Published private(set) var elapsed: Double = 0
    @Published var systemAudio = AppPreferences.standard.object(forKey: "recordSystemAudio") == nil || AppPreferences.standard.bool(forKey: "recordSystemAudio") { didSet { preferences.set(systemAudio, forKey: "recordSystemAudio") } }
    @Published var microphone = AppPreferences.standard.bool(forKey: "recordMicrophone") {
        didSet {
            guard preferencesLoaded else { return }
            preferences.set(microphone, forKey: cameraEnabled ? "recordCameraMicrophone" : "recordMicrophone")
        }
    }
    private func microphonePreference(camera: Bool) -> Bool {
        // Legacy screen-only silence is not an explicit camera-mode mute.
        camera ? (preferences.object(forKey: "recordCameraMicrophone") as? Bool ?? true)
               : preferences.bool(forKey: "recordMicrophone")
    }
    @Published var showsCursor = AppPreferences.standard.object(forKey: "recordCursor") == nil || AppPreferences.standard.bool(forKey: "recordCursor") { didSet { preferences.set(showsCursor, forKey: "recordCursor") } }
    @Published var fps = AppPreferences.standard.integer(forKey: "recordFPS") == 60 ? 60 : 30 { didSet { preferences.set(fps, forKey: "recordFPS") } }
    @Published var captureInteractions = AppPreferences.standard.object(forKey: "recordInteractions") == nil || AppPreferences.standard.bool(forKey: "recordInteractions") { didSet { preferences.set(captureInteractions, forKey: "recordInteractions") } }
    @Published var captureShortcuts = AppPreferences.standard.bool(forKey: "recordShortcuts") { didSet { preferences.set(captureShortcuts, forKey: "recordShortcuts") } }
    @Published var smoothCursor = AppPreferences.standard.bool(forKey: "recordSmoothCursor") { didSet { preferences.set(smoothCursor, forKey: "recordSmoothCursor") } }
    @Published var cameraEnabled = AppPreferences.standard.bool(forKey: "recordCamera") {
        didSet {
            preferences.set(cameraEnabled, forKey: "recordCamera")
            if preferencesLoaded && cameraEnabled != oldValue {
                microphone = microphonePreference(camera: cameraEnabled)
            }
        }
    }
    @Published var cameraDeviceID = AppPreferences.standard.string(forKey: "recordCameraDevice") ?? "" { didSet { preferences.set(cameraDeviceID, forKey: "recordCameraDevice") } }
    @Published private(set) var warning: String?
    var recordedWithCamera: Bool { captured.camera }
    private(set) var captureStatistics = RecordingCaptureStatistics()
    private(set) var cameraStopEvent: RecordingCamera.StopEvent?
    let camera = RecordingCamera()
    private var cameraActive = false
    private var cameraUnavailable = false
    private var cameraOffset = 0.0
    private var cameraSegments: [CameraRecordingSegment] = []
    lazy var drawing = RecordingDrawingController(recorder: self)
    lazy var speakerNotes = SpeakerNotesController(preferences: preferences)
    private let regionOverlay = RecordingRegionOverlay()
    var currentRecordingTime: Double { previousDuration + (segmentStarted.map { Date().timeIntervalSince($0) } ?? 0) }
    var onFinish: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    private var stream: SCStream?
    private var fragmentWriter: FragmentedScreenWriter?
    private var segmentError: Error?
    private var sessionJournal: RecordingSessionJournal?
    private var sessionSegments: [RecordingSessionSegment] = []
    private var checkpointTask: Task<Void, Error>?
    private var checkpointEvents = 0
    private var checkpointDrawing = 0
    private var lastCheckpoint = 0.0
    private var sessionCompleted = false
    private var sessionToken = UUID()
    private var segments: [URL] = []
    private var directory: URL?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var timer: Timer?
    private var segmentStarted: Date?
    private var previousDuration: Double = 0
    private var interactions: [RecordedInteraction] = []
    private var eventMonitors: [Any] = []
    private var pointerTimer: Timer?
    private(set) var recordingBounds: CGRect = .zero
    private var recordedWindowID: CGWindowID?
    private var lastWindowCheck = 0.0
    private var captureTopology: DesktopTopology?
    private var displayObserver: NSObjectProtocol?
    private var lastPointer: CGPoint?
    private var lastPointerTime = -Double.infinity
    private var lastStorageCheck = 0.0
    private struct CaptureOptions {
        var fps = 30
        var audio = true, microphone = false, cursor = true, smooth = false, interactions = true, shortcuts = false, camera = false
        var cameraID = ""
        var audioSources: [String] { [audio ? "system" : nil, microphone ? "microphone" : nil].compactMap { $0 } }
    }
    private var captured = CaptureOptions()

    func start(screen: NSScreen, rect: CGRect, content: SCShareableContent, diagnostic: Bool = false, window: SCWindow? = nil,
               diagnosticSource: SCWindow? = nil) async throws {
        guard state == .idle else { throw CaptureError.message(L10n.text("已有录屏正在进行。")) }
        captured = CaptureOptions(fps: fps, audio: systemAudio, microphone: microphone, cursor: showsCursor, smooth: smoothCursor, interactions: captureInteractions, shortcuts: captureShortcuts, camera: cameraEnabled, cameraID: cameraDeviceID)
        drawing.reset(); state = .preparing; warning = nil
        var startupSucceeded = false
        defer { if !startupSucceeded { reset() } }
        if diagnostic {
            try DiagnosticRecordingSource.require(window ?? diagnosticSource)
            captured.interactions=false;captured.shortcuts=false
        }
        if captured.shortcuts && !AXIsProcessTrusted() {
            throw CaptureError.message(L10n.text("显示快捷键需要辅助功能权限。可先在设置中关闭“快捷键徽标”，继续录屏。"))
        }
        let topology = DesktopTopology.current(), geometry = try topology.display(for: screen)
        if window == nil { _ = try geometry.sourceRect(rect) }
        else if ![rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) || rect.width <= 0 || rect.height <= 0 { throw CaptureError.message(L10n.text("窗口录制尺寸无效。")) }
        guard let display = content.displays.first(where: { $0.displayID == geometry.id }) else { throw CaptureError.message(L10n.text("显示器已断开。")) }
        if captured.microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw CaptureError.message(L10n.text("麦克风未授权。可以关闭麦克风，只录制系统声音。")) }
        }
        let storage = diagnostic ? FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-recording-diagnostics", isDirectory: true) : RecordingLibrary.directory
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try RecordingStorageBudget.require(storage, bytes: 512_000_000)
        }.value
        if captured.camera { try await camera.prepare(deviceID: captured.cameraID.isEmpty ? nil : captured.cameraID) }
        cameraActive = captured.camera; cameraUnavailable = false; cameraStopEvent = nil; cameraSegments = []
        var own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        if window == nil && own.isEmpty {
            let inventory = try await captureWithTimeout { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
            own = inventory.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        }
        if let target = window?.windowID, target == speakerNotes.windowID { throw CaptureError.message(L10n.text("提词窗口不能作为录制目标。")) }
        speakerNotes.configureCapture(excluded: window != nil || !own.isEmpty, screen: screen)
        if let window { filter=SCContentFilter(desktopIndependentWindow:window) }
        else if diagnostic, let diagnosticSource {
            let generated=SCContentFilter(display:display,including:[diagnosticSource]);generated.includeMenuBar=false
            filter=generated
        } else { filter=SCContentFilter(display:display,excludingApplications:own,exceptingWindows:[]) }
        recordedWindowID = window?.windowID; lastWindowCheck = 0
        let config = SCStreamConfiguration()
        if window == nil { config.sourceRect = try geometry.sourceRect(rect) }
        // Even dimensions are required by H.264 encoders; cap at 4K for predictable resource use.
        let pixelScale = window.map { CGFloat(SCContentFilter(desktopIndependentWindow: $0).pointPixelScale) } ?? geometry.scale
        let scale = min(pixelScale, 3840 / max(rect.width, rect.height))
        config.width = max(2, Int(rect.width * scale) / 2 * 2)
        config.height = max(2, Int(rect.height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(captured.fps))
        config.queueDepth = 5; config.showsCursor = captured.cursor && !captured.smooth
        config.capturesAudio = captured.audio; config.excludesCurrentProcessAudio = true
        config.captureMicrophone = captured.microphone
        config.sampleRate = 48000; config.channelCount = 2
        configuration = config
        directory = storage.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionDirectory = directory!
        try await Task.detached(priority: .utility) { try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true) }.value
        sessionJournal = try await RecordingSessionJournal.create(directory: sessionDirectory, fps: captured.fps, smoothCursor: captured.smooth && captured.cursor, audioSources: captured.audioSources)
        sessionSegments = []; checkpointEvents = 0; checkpointDrawing = 0; checkpointTask = nil; sessionCompleted = false; sessionToken = UUID(); lastCheckpoint = 0
        segments = []; elapsed = 0; previousDuration = 0; captureStatistics = RecordingCaptureStatistics(); state = .preparing; lastStorageCheck = 0
        interactions = []; lastPointer = nil; lastPointerTime = -Double.infinity
        recordingBounds = rect.offsetBy(dx: geometry.frame.minX, dy: geometry.frame.minY)
        try topology.requireUnchanged(); captureTopology = topology; watchTopology()
        do {
            try await beginSegment()
            if !diagnostic { regionOverlay.update(bounds: recordingBounds) }
            monitorInteractions(); startupSucceeded = true
        } catch { reset(); throw error }
    }

    private func beginSegment() async throws {
        guard let filter, let configuration, let directory else { throw CaptureError.message(L10n.text("录屏配置已失效。")) }
        guard segments.count < 1000 else { throw CaptureError.message(L10n.text("分段已达1000段，请结束保存后新建录制。")) }
        try captureTopology?.requireUnchanged()
        let url = directory.appendingPathComponent("segment-\(segments.count).mov")
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let width = configuration.width, height = configuration.height, fps = captured.fps, audio = captured.audio, microphone = captured.microphone, lease = sessionJournal?.lease
        let writer = try await Task.detached(priority: .userInitiated) { [self] in
            try FragmentedScreenWriter(url: url, width: width, height: height, fps: fps, systemAudio: audio, microphone: microphone, lease: lease) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.segments.last == url else { return }
                    self.segmentError = error
                    if self.state == .recording { self.warning = L10n.text("录制写入中断，正在保留恢复素材。"); await self.stop() }
                }
            }
        }.value
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if audio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if microphone { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
        self.stream = stream; fragmentWriter = writer; segmentError = nil
        segments.append(url)
        let cameraURL = directory.appendingPathComponent("camera-segment-\(segments.count - 1).mov")
        sessionSegments.append(.init(video: url.lastPathComponent, sourceStart: previousDuration, camera: cameraActive && !cameraUnavailable ? cameraURL.lastPathComponent : nil))
        try await queueCheckpoint(.preparing).value
        let cameraStarted = cameraActive && !cameraUnavailable ? try await camera.begin(cameraURL, recoveryLease: lease) : nil
        try captureTopology?.requireUnchanged()
        try await stream.startCapture()
        let began = try await writer.waitForStart(); if let segmentError { throw segmentError }
        try captureTopology?.requireUnchanged()
        cameraOffset = cameraStarted.map { max(0, began.timeIntervalSince($0)) } ?? 0
        sessionSegments[sessionSegments.count - 1].cameraOffset = cameraOffset
        state = .recording; segmentStarted = began
        try await queueCheckpoint(.recording).value
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.state == .recording else { return }
                let session = self.sessionToken
                if ProcessInfo.processInfo.systemUptime - self.lastStorageCheck > 5, let directory = self.directory {
                    self.lastStorageCheck = ProcessInfo.processInfo.systemUptime; let token = self.sessionToken
                    let enough = await Task.detached(priority: .utility) { (try? RecordingStorageBudget.require(directory, bytes: 256_000_000)) != nil }.value
                    guard self.sessionToken == token, self.state == .recording else { return }
                    if !enough { self.warning = L10n.text("空间不足，正在结束录制并保留可恢复原片。"); await self.stop(); return }
                }
                if ProcessInfo.processInfo.systemUptime - self.lastCheckpoint > 2 {
                    self.lastCheckpoint = ProcessInfo.processInfo.systemUptime
                    do { try await self.queueCheckpoint(.recording).value }
                    catch { self.warning = L10n.text("恢复检查点未保存，正在结束录制保留原片。"); await self.stop(); return }
                }
                guard self.sessionToken == session, self.state == .recording else { return }
                if self.recordedWindowID != nil && ProcessInfo.processInfo.systemUptime - self.lastWindowCheck > 0.5 {
                    self.lastWindowCheck = ProcessInfo.processInfo.systemUptime
                    guard self.refreshWindowBounds() else { self.warning = L10n.text("窗口已关闭，已结束并保存录屏。"); await self.stop(); return }
                }
                self.elapsed = self.previousDuration + (self.segmentStarted.map { Date().timeIntervalSince($0) } ?? 0)
            }
        }
    }

    func togglePause() async {
        guard state == .recording || state == .paused else { return }
        do {
            if state == .recording {
                drawing.stopDrawing(); state = .preparing; try await finishSegment(); state = .paused; try await queueCheckpoint(.paused).value
            } else { state = .preparing; try await beginSegment() }
        } catch { reset(); onError?(error) }
    }

    private func finishSegment() async throws {
        guard let stream, let writer = fragmentWriter else { return }
        timer?.invalidate(); timer = nil
        let priorDuration = previousDuration
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        if let segmentStarted { previousDuration += Date().timeIntervalSince(segmentStarted) }
        self.segmentStarted = nil; elapsed = previousDuration
        try await captureWithTimeout(10) { try await stream.stopCapture() }
        let report = try await writer.finish(at: stopTime)
        captureStatistics.append(report)
        if captureStatistics.droppedVideo > 0 || captureStatistics.droppedAudio > 0 {
            warning = L10n.text("录制负载较高：累计跳过\(captureStatistics.droppedVideo)个画面样本、\(captureStatistics.droppedAudio)个声音样本。原片已保留；可缩小录制区域或减少同时运行的任务。")
        }
        self.stream = nil; fragmentWriter = nil
        if let segment = segments.last, let duration = try? await AVURLAsset(url: segment).load(.duration), duration.isNumeric {
            previousDuration = priorDuration + duration.seconds; elapsed = previousDuration
        }
        if cameraActive {
            do {
                let url = try await camera.end()
                cameraSegments.append(CameraRecordingSegment(url: url, offset: cameraOffset, duration: previousDuration - priorDuration))
            } catch {
                warning = L10n.text("摄像头片段未完成，屏幕录制已保留。")
                cameraSegments.append(CameraRecordingSegment(url: nil, offset: 0, duration: previousDuration - priorDuration))
                cameraActive = false; camera.shutdown()
            }
        } else if captured.camera { cameraSegments.append(CameraRecordingSegment(url: nil, offset: 0, duration: previousDuration - priorDuration)) }
        if cameraUnavailable { cameraActive = false; camera.shutdown() }
        if !sessionSegments.isEmpty { sessionSegments[sessionSegments.count - 1].duration = previousDuration - priorDuration; sessionSegments[sessionSegments.count - 1].sealed = true }
        try await queueCheckpoint(.finishing).value
    }
    func stop() async {
        guard state == .recording || state == .paused else { return }
        regionOverlay.close()
        drawing.close()
        let wasPaused = state == .paused; state = .finishing
        do {
            if !wasPaused { try await finishSegment() }
            guard let directory else { throw CaptureError.message(L10n.text("没有找到录屏文件。")) }
            let sources = segments + cameraSegments.compactMap(\.url)
            try await Task.detached(priority: .utility) {
                let bytes = try sources.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                try RecordingStorageBudget.require(directory, bytes: bytes * 2 + 256_000_000)
            }.value
            let result = directory.appendingPathComponent("DeskCapture-\(Int(Date().timeIntervalSince1970)).mp4")
            try await Self.join(segments, to: result)
            if cameraSegments.contains(where: { $0.url != nil }) {
                do { try await CameraRecordingSegment.join(cameraSegments, to: RecordingCamera.url(for: result), microphoneSources: segments, audioSources: captured.audioSources) }
                catch { warning = L10n.text("摄像头合成失败，屏幕视频和原始分段已保留。") + " " + error.localizedDescription }
            }
            var metadata = RecordingInteractions(smoothCursor: captured.smooth && captured.cursor, events: interactions)
            metadata.recordedFPS = captured.fps
            metadata.audioSources = captured.audioSources
            let metadataSnapshot = metadata, timeline = drawing.timeline
            let hasDrawing = timeline.frames.contains { !$0.marks.isEmpty }
            try await Task.detached(priority: .userInitiated) {
                try JSONEncoder().encode(metadataSnapshot).write(to: RecordingInteractions.url(for: result), options: .atomic)
                if hasDrawing { try JSONEncoder().encode(timeline).write(to: RecordingDrawingTimeline.url(for: result), options: .atomic) }
            }.value
            if (captured.smooth && captured.cursor) || hasDrawing {
                let processed = directory.appendingPathComponent("DeskCapture-标注成片.mp4")
                var options = RecordingEffectsOptions()
                options.smartZoom = false; options.background = false; options.shortcuts = false; options.camera.enabled = false
                do { try await RecordingEffectsExporter.export(result, to: processed, options: options) }
                catch { warning = L10n.text("标注成片处理失败，已保留原始视频和标注时间轴。"); try await queueCheckpoint(.completed, finalFile: result.lastPathComponent).value; sessionCompleted = true; reset(); onFinish?(result); return }
                metadata.smoothCursor = false
                metadata.editableCursorSource = captured.smooth && captured.cursor ? result.lastPathComponent : nil
                let processedMetadata = metadata
                try await Task.detached(priority: .userInitiated) {
                    if FileManager.default.fileExists(atPath: RecordingCamera.url(for: result).path) {
                        try FileManager.default.copyItem(at: RecordingCamera.url(for: result), to: RecordingCamera.url(for: processed))
                    }
                    try JSONEncoder().encode(processedMetadata).write(to: RecordingInteractions.url(for: processed), options: .atomic)
                }.value
                try await queueCheckpoint(.completed, finalFile: processed.lastPathComponent).value; sessionCompleted = true; reset(); onFinish?(processed); return
            }
            try await queueCheckpoint(.completed, finalFile: result.lastPathComponent).value; sessionCompleted = true; reset(); onFinish?(result)
        } catch { reset(); onError?(error) }
    }

    static func join(_ segments: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.message(L10n.text("无法创建视频导出轨道。"))
        }
        var audioTracks: [Int: AVMutableCompositionTrack] = [:]
        var sourceAssets: [AVURLAsset] = []
        defer { withExtendedLifetime(sourceAssets) {} }
        var time = CMTime.zero
        for url in segments {
            let asset = AVURLAsset(url: url); sourceAssets.append(asset)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration > .zero, let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            try await RecordingVideoTimeline.append(track, sourceDuration: duration, to: video, at: time)
            video.preferredTransform = try await track.load(.preferredTransform)
            for (index, audio) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                if audioTracks[index] == nil {
                    audioTracks[index] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                let available = CMTimeRangeGetIntersection(CMTimeRange(start: .zero, duration: duration), otherRange: try await audio.load(.timeRange))
                if available.duration > .zero { try audioTracks[index]?.insertTimeRange(available, of: audio, at: time + available.start) }
            }
            time = time + duration
        }
        guard time > .zero, let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.message(L10n.text("录屏太短，没有可导出的视频帧。"))
        }
        try await VideoExport.export(exporter, to: output, as: .mp4)
    }

    @discardableResult private func refreshWindowBounds() -> Bool {
        guard let id = recordedWindowID else { return true }
        guard let window = CaptureWindowInfo.read(id), window.isOnScreen != false else { return false }
        let frame = window.frame
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        recordingBounds = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        drawing.followBounds()
        if !regionOverlay.panels.isEmpty { regionOverlay.update(bounds: recordingBounds) }
        return true
    }
    private func watchTopology() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let topology = self.captureTopology else { return }
                do { try topology.requireUnchanged() }
                catch {
                    self.segmentError = error
                    self.warning = L10n.text("显示器参数已改变，正在结束录制并保留原始素材。")
                    self.fragmentWriter?.finishInBackground()
                    if self.state == .recording || self.state == .paused { Task { await self.stop() } }
                }
            }
        }
    }
    private func reset() {
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver); self.displayObserver = nil }
        captureTopology = nil
        if sessionJournal != nil && !sessionCompleted { _ = queueCheckpoint(.interrupted) }
        sessionJournal = nil; checkpointTask = nil; fragmentWriter?.finishInBackground(); fragmentWriter = nil
        if let stream { Task { try? await stream.stopCapture() } }
        regionOverlay.close()
        drawing.close(); camera.shutdown(); cameraActive = false; recordedWindowID = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        eventMonitors.forEach { NSEvent.removeMonitor($0) }; eventMonitors = []
        timer?.invalidate(); timer = nil; stream = nil
        segmentStarted = nil; state = .idle; filter = nil; configuration = nil
    }
    private func queueCheckpoint(_ status: RecordingSessionManifest.Status, finalFile: String? = nil) -> Task<Void, Error> {
        guard let journal = sessionJournal else { return Task {} }
        let events = Array(interactions.dropFirst(checkpointEvents)), frames = Array(drawing.timeline.frames.dropFirst(checkpointDrawing)), snapshot = sessionSegments
        checkpointEvents = interactions.count; checkpointDrawing = drawing.timeline.frames.count
        let previous = checkpointTask
        let task = Task { try await previous?.value; try await journal.checkpoint(segments: snapshot, status: status, events: events, drawing: frames, finalFile: finalFile) }
        checkpointTask = task; return task
    }
    private func monitorInteractions() {
        guard captured.interactions || captured.smooth || captured.shortcuts else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.recordInteraction(.click) }
        }) { eventMonitors.append(monitor) }
        if captured.shortcuts, let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !modifiers.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers, !key.isEmpty, !event.isARepeat else { return }
            let label = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
                (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key.uppercased()
            Task { @MainActor in self?.recordInteraction(.shortcut, label: label) }
        }) { eventMonitors.append(monitor) }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordInteraction(.pointer) }
        }
    }
    private func recordInteraction(_ kind: RecordedInteraction.Kind, label: String? = nil) {
        guard state == .recording, let segmentStarted, recordingBounds.width > 0 else { return }
        if kind != .shortcut && !captured.interactions && !captured.smooth { return }
        let location = NSEvent.mouseLocation
        guard recordingBounds.contains(location) || kind == .shortcut else { return }
        let point = CGPoint(x: min(1, max(0, (location.x - recordingBounds.minX) / recordingBounds.width)),
                            y: min(1, max(0, (location.y - recordingBounds.minY) / recordingBounds.height)))
        let time = previousDuration + Date().timeIntervalSince(segmentStarted)
        if kind == .pointer, let lastPointer, hypot(point.x - lastPointer.x, point.y - lastPointer.y) < 0.0002,
           time - lastPointerTime < 0.2 { return }
        if kind == .pointer { lastPointer = point; lastPointerTime = time }
        interactions.append(RecordedInteraction(time: time,
                                                x: point.x, y: point.y, kind: kind, label: label))
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.segmentError = error
            if state == .recording { warning = L10n.text("系统录制中断，正在保存可恢复内容。"); await stop() }
        }
    }
}
