import AppKit
import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

final class LauncherPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        level = .floating
        hidesOnDeactivate = false
    }
    func restorePresentation(in visibleFrame: NSRect) {
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        alphaValue = 1
        if isMiniaturized { deminiaturize(nil) }
        setFrame(CapturePanelGeometry.clamp(frame, to: visibleFrame), display: true)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func performClose(_ sender: Any?) { orderOut(nil) }
}

final class VideoResultPanel: NSWindow, NSWindowDelegate {
    var editSession: VideoEditSession?
    override var undoManager: UndoManager? { editSession.map { $0.busy ? nil : $0.undoManager } ?? super.undoManager }
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        delegate = self
    }
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        // The editor records whole parameter snapshots, including numeric fields.
        // Do not also register AppKit text-range inverses for the same operation.
        (editor as? NSTextView)?.allowsUndo = false
        return editor
    }
    @objc func undo(_ sender: Any?) {
        guard let editSession, !editSession.busy else { return }
        makeFirstResponder(nil)
        if let state = editSession.capture?() { editSession.record(state) }
        editSession.undoManager.undo(); editSession.refresh()
    }
    @objc func redo(_ sender: Any?) {
        guard let editSession, !editSession.busy else { return }
        makeFirstResponder(nil)
        editSession.undoManager.redo(); editSession.refresh()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == .command || flags == [.command, .shift] {
            if flags.contains(.shift) { redo(nil) } else { undo(nil) }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        makeFirstResponder(nil)
        return editSession?.shouldClose() ?? true
    }
    func windowWillClose(_ notification: Notification) {
        editSession?.didClose?()
        editSession = nil
        // The coordinator retains closed windows. Release the hosting tree and
        // player now rather than waiting for the next recording to open.
        contentView = nil
    }

    static func initialFrame(in visible: NSRect) -> NSRect {
        let size = NSSize(width: min(1120, visible.width), height: min(760, visible.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }
}

struct RecordingConfigurationView: View {
    @ObservedObject var recorder: ScreenRecorder
    var grouped = false
    @State private var showPresentationOptions = false
    @State private var cameras: [RecordingCameraChoice] = []
    @State private var loadingCameras = false

    var body: some View {
        VStack(alignment: .leading, spacing: grouped ? 20 : 8) {
            if grouped {
                SettingsGroup(title: L10n.text("声音"), symbol: "speaker.wave.2") { audioControls }
                SettingsGroup(title: L10n.text("画面"), symbol: "video") { pictureControls }
                SettingsGroup(title: L10n.text("演示"), symbol: "cursorarrow.rays") { presentationControls }
            } else {
                audioControls
                Divider()
                pictureControls
                Divider()
                presentationControls
            }
        }.font(.system(size: 13)).disabled(recorder.state != .idle)
            .task(id: recorder.cameraEnabled) {
                guard recorder.cameraEnabled else { return }
                loadingCameras = true
                let devices = await Task.detached(priority: .userInitiated) {
                    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                    mediaType: .video, position: .unspecified).devices.map {
                        RecordingCameraChoice(id: $0.uniqueID, title: $0.localizedName)
                    }
                }.value
                guard !Task.isCancelled else { return }
                cameras = devices
                loadingCameras = false
            }
    }
    private var audioControls: some View {
        Group {
            SettingsToggle(title: L10n.text("系统声音"), isOn: $recorder.systemAudio)
            SettingsToggle(title: L10n.text("麦克风"), isOn: $recorder.microphone)
        }
    }
    private var pictureControls: some View {
        Group {
            SettingsRow(title: L10n.text("帧率")) {
                Picker(L10n.text("帧率"), selection: $recorder.fps) { Text("30 FPS").tag(30); Text("60 FPS").tag(60) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: grouped ? 200 : 150, alignment: .trailing)
            }
            if recorder.fps == 60 {
                Text(L10n.text("60 FPS 为目标帧率，实际帧率受录制范围和电脑性能影响，可能低于 60 FPS。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            SettingsToggle(title: L10n.text("显示光标"), isOn: $recorder.showsCursor)
            Divider()
            SettingsToggle(title: L10n.text("摄像头画中画"), isOn: $recorder.cameraEnabled)
            if recorder.cameraEnabled {
                SettingsRow(title: L10n.text("摄像头")) {
                    Picker(L10n.text("摄像头"), selection: $recorder.cameraDeviceID) {
                        Text(L10n.text("系统默认")).tag("")
                        ForEach(cameras) { Text($0.title).tag($0.id) }
                        if !recorder.cameraDeviceID.isEmpty && !cameras.contains(where: { $0.id == recorder.cameraDeviceID }) {
                            Text(loadingCameras ? L10n.text("正在读取设备…") : L10n.text("所选摄像头不可用")).tag(recorder.cameraDeviceID)
                        }
                    }.labelsHidden().frame(width: grouped ? 240 : 180, alignment: .trailing)
                }
            }
        }
    }
    private var presentationControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: L10n.text("提词稿")) {
                Button(L10n.text("编辑提词稿…")) { recorder.speakerNotes.showEditor() }.buttonStyle(StudioButtonStyle(command: true))
            }
            Divider()
            DisclosureGroup(L10n.text("演示效果"), isExpanded: $showPresentationOptions) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsToggle(title: L10n.text("记录点击"), isOn: $recorder.captureInteractions)
                    if recorder.showsCursor {
                        SettingsToggle(title: L10n.text("平滑光标"), isOn: $recorder.smoothCursor)
                    }
                    SettingsToggle(title: L10n.text("快捷键徽标"), isOn: $recorder.captureShortcuts)
                    if recorder.captureShortcuts && !AXIsProcessTrusted() {
                        SettingsRow(title: L10n.text("辅助功能权限")) {
                            Button(L10n.text("前往授权…")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }.buttonStyle(StudioButtonStyle(command: true))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.padding(.vertical, 12)
        }
    }
}

private struct RecordingCameraChoice: Identifiable, Sendable {
    let id: String
    let title: String
}

enum VideoEditorTool: String, CaseIterable, Identifiable {
    case edit = "剪辑", picture = "画面", audio = "声音", captions = "字幕"
    var id: Self { self }
    var symbol: String {
        switch self { case .edit: "scissors"; case .picture: "rectangle.on.rectangle"; case .audio: "waveform"; case .captions: "captions.bubble" }
    }
    var heading: String {
        switch self {
        case .edit: return L10n.text("片段与变速")
        case .picture: return L10n.text("画布与演示效果")
        case .audio: return L10n.text("声音处理")
        case .captions: return L10n.text("字幕与按句删剪")
        }
    }
    var detail: String {
        switch self {
        case .edit: return L10n.text("裁剪范围，按顺序拼接片段和调整速度。")
        case .picture: return L10n.text("调整背景、画布、放大镜头和摄像头画中画。")
        case .audio: return L10n.text("调整录制声音、背景音乐与淡入淡出。")
        case .captions: return L10n.text("转写或导入字幕；取消保留的句子会从成片中删除。")
        }
    }
}

struct VideoResultView: View {
    let url: URL
    var imported = false
    var recordingWarning: String?
    var copiedOriginal = false
    var cameraWasRequested = false
    let close: () -> Void
    var openProject: (() -> Void)? = nil
    @State private var exporting = false
    @State private var cancellingExport = false
    @State private var exportGeneration = UUID()
    @State private var exportOperation = L10n.text("正在处理…")
    @State private var exportProgressAvailable = false
    @State private var exportSavePanel: NSSavePanel?
    @State private var messageKind: StudioMessageKind = .information
    @State private var message: String?
    @State private var tool = VideoEditorTool.edit
    @State private var duration = 0.0
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @StateObject private var playbackController = VideoEditorPlaybackController()
    private var player: AVPlayer { playbackController.player }
    @State private var effects = RecordingEffectsOptions()
    @State private var hasInteractions = false
    @State private var hasEditableCursor = false
    @State private var audioSources: [RecordingAudioSource] = []
    @State private var cameraMaterial = RecordingCameraMaterial.checking
    @State private var cameraExpanded = false
    @State private var sourceVideoSize = CGSize(width: 1920, height: 1080)
    @State private var captions: [CaptionSegment] = []
    @State private var speechTask: Task<Void, Never>?
    @State private var captionSaveTask: Task<Void, Never>?
    @State private var captionSaving = false
    @State private var editFingerprint: String?
    @State private var editSaveFailed = false
    @State private var speechLanguage = "zh-CN"
    @State private var localSpeech = true
    @State private var speechTier = LocalSpeechTier.base
    @State private var showSpeechModels = false
    @State private var speechStatus: String?
    @State private var lenses: [RecordingLens] = []
    @State private var lensX = 0.5
    @State private var lensY = 0.5
    @State private var lensZoom = 2.0
    @State private var lensDuration = 2.0
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress = 0.0
    @State private var lastExportedURL: URL?
    @State private var previewPlayback: RecordingEffectsPlayback?
    @State private var previewRevision = 0
    @State private var liveFrameRevision = 0
    @State private var previewReady = false
    @State private var previewUpdating = false
    @State private var previewError: String?
    @State private var showOriginal = false
    @State private var cameraVideoSize = CGSize(width: 16, height: 9)
    @State private var cameraDragOrigin: CGPoint?
    @State private var pendingSourceTime: Double?
    @StateObject private var editSession = VideoEditSession()
    init(url: URL, imported: Bool = false, recordingWarning: String? = nil, copiedOriginal: Bool = false,
         cameraWasRequested: Bool = false, close: @escaping () -> Void, openProject: (() -> Void)? = nil,
         initialTool: VideoEditorTool = .edit) {
        self.url = url; self.imported = imported; self.recordingWarning = recordingWarning
        self.copiedOriginal = copiedOriginal; self.cameraWasRequested = cameraWasRequested
        self.close = close; self.openProject = openProject
        _tool = State(initialValue: initialTool)
    }
    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            HSplitView {
                previewPane.frame(minWidth: 370, maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(minWidth: 380, idealWidth: 400, maxWidth: 440, maxHeight: .infinity)
            }
            if let status = message ?? recordingWarning {
                Divider()
                StudioMessage(text: status, kind: message == nil ? .warning : messageKind,
                              dismiss: message == nil ? nil : { message = nil }).padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            editorDelivery
        }
        .foregroundStyle(Palette.white).background(Palette.ink)
            .buttonStyle(StudioButtonStyle(command: true))
            .background(VideoEditWindowBinding(session: editSession).frame(width: 0, height: 0))
            .onChange(of: editState) { _, state in
                if previewReady { editSession.record(state) }
            }
            .onChange(of: editorBusy) { _, busy in editSession.busy = busy }
            .onChange(of: exporting) { _, value in if !value { cancellingExport = false } }
            .onDisappear {
                stopEditor()
            }
            .task(id: previewRevision) { await updatePreview() }
            .task(id: liveFrameRevision) { await refreshLiveFrame() }
            .onChange(of: effects) { old, new in effectsChanged(from: old, to: new) }
            .onChange(of: captions) { _, _ in requestPreviewUpdate() }
            .onChange(of: lenses) { _, _ in requestPreviewUpdate() }
            .onChange(of: trimStart) { _, _ in requestPreviewUpdate() }
            .onChange(of: trimEnd) { _, _ in requestPreviewUpdate() }
            .task(id: showOriginal) { await switchPreviewMode() }
            .onChange(of: playbackController.failure) { _, error in
                if let error { previewError = error }
            }
            .task {
                let input = url
                let initial = await Task.detached(priority: .utility) {
                    let metadata = RecordingInteractions.load(input)
                    let before = try? RecordingEditStore.fingerprint(input)
                    let snapshot = try? RecordingEditStore.load(input)
                    let rows = snapshot?.captions ?? VideoTranscript.load(input), studio = snapshot?.studio ?? RecordingStudioProject.load(input)
                    let after = try? RecordingEditStore.fingerprint(input)
                    let consistent = before != nil && before == after && (!RecordingEditStore.exists(input) || snapshot != nil)
                    let camera = try? await RecordingCameraMaterial.inspect(for: input)
                    let audio = (try? await RecordingAudioSource.inspect(input)) ?? []
                    return (rows, studio,
                            metadata?.events.contains { $0.kind == .click || $0.kind == .shortcut } == true,
                            (try? EditableCursorSource.resolve(input, metadata: metadata)) != nil, consistent ? after : nil, camera ?? .unreadable, audio)
                }.value
                guard !Task.isCancelled else { return }
                captions = initial.0
                let studio = initial.1
                lenses = studio.lenses
                if let saved = studio.effects { effects = saved }
                hasInteractions = initial.2
                hasEditableCursor = initial.3
                cameraMaterial = initial.5; audioSources = initial.6
                editFingerprint = initial.4
                if initial.4 == nil { report(L10n.text("工程文件无效或读取期间发生改变，保存已停用；现有文件保持，请重新打开。"), kind: .error) }
                if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds, seconds.isFinite {
                    guard !Task.isCancelled else { return }
                    duration = seconds; trimStart = min(seconds, max(0, studio.trimStart ?? 0)); trimEnd = min(seconds, studio.trimEnd ?? seconds)
                }
                if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                    guard !Task.isCancelled else { return }
                    let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
                    if bounds.width > 0 && bounds.height > 0 { sourceVideoSize = bounds.size }
                }
                guard !Task.isCancelled else { return }
                if cameraMaterial == .ready || cameraMaterial == .unreadable || cameraWasRequested {
                    cameraExpanded = true
                    if let cameraTrack = try? await AVURLAsset(url: RecordingCamera.url(for: url)).loadTracks(withMediaType: .video).first,
                       let size = try? await cameraTrack.load(.naturalSize), let transform = try? await cameraTrack.load(.preferredTransform) {
                        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
                        if bounds.width > 0 && bounds.height > 0 { cameraVideoSize = bounds.size }
                    }
                }
                guard !Task.isCancelled else { return }
                editSession.apply = { state in
                    effects = state.effects; captions = state.captions; lenses = state.lenses
                    trimStart = state.start; trimEnd = state.end
                }
                editSession.saveAndClose = { startCaptionSave(closeAfter: true) }
                editSession.capture = { editState }
                editSession.didClose = { stopEditor() }
                editSession.begin(editState)
                previewReady = true; requestPreviewUpdate()
            }
    }

    private func stopEditor() {
        previewReady = false
        speechTask?.cancel(); captionSaveTask?.cancel(); exportTask?.cancel()
        exportGeneration = UUID()
        exportSavePanel?.cancel(nil); exportSavePanel = nil
        exporting = false; cancellingExport = false; exportTask = nil
        playbackController.stop(); previewPlayback = nil
        editSession.detach()
    }
    private var editState: VideoEditState {
        .init(effects: effects, captions: captions, lenses: lenses, start: trimStart, end: trimEnd)
    }
    private var editorBusy: Bool { exporting || captionSaving || captionSaveTask != nil || speechTask != nil }
    private var cameraOutputUnavailable: Bool {
        cameraMaterial.blocksComposition(enabled: effects.camera.enabled, requested: cameraWasRequested)
    }
    private var compositionUnavailable: Bool { duration <= 0 || editFingerprint == nil || cameraOutputUnavailable }
    private var editorToolbar: some View {
        StudioToolbar {
            EditorBarTitle(title: L10n.text("视频编辑"), detail: url.lastPathComponent)
        } tools: {
                StudioIconButton(title: L10n.text("撤销"), symbol: "arrow.uturn.backward") { editSession.undoManager.undo(); editSession.refresh() }
                    .disabled(!editSession.undoManager.canUndo || editorBusy)
                StudioIconButton(title: L10n.text("重做"), symbol: "arrow.uturn.forward") { editSession.undoManager.redo(); editSession.refresh() }
                    .disabled(!editSession.undoManager.canRedo || editorBusy)
                StudioMenu(cameraMaterial == .ready ? L10n.text("原片素材") : L10n.text("原片")) {
                    Button(cameraMaterial == .ready ? L10n.text("打开屏幕原片") : L10n.text("打开原片")) { NSWorkspace.shared.open(url) }
                    if cameraMaterial == .ready {
                        Button(L10n.text("打开摄像头原片")) { NSWorkspace.shared.open(RecordingCamera.url(for: url)) }
                    }
                    Button(cameraMaterial == .ready ? L10n.text("复制屏幕原片") : L10n.text("复制原片文件")) { copyOriginalFile() }
                    Button(cameraMaterial == .ready ? L10n.text("另存屏幕原片…") : L10n.text("另存原片…")) { save(asGIF: false) }
                    Button(L10n.text("导出原片 GIF…")) { save(asGIF: true) }.disabled(duration <= 0)
                    Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.fixedSize()
                StudioMenu(L10n.text("项目")) {
                    Button(L10n.text("打开项目…")) { openProject?() }.disabled(openProject == nil)
                    Button(L10n.text("导出可编辑项目（含原片）…")) { exportProject(delivery: false) }.disabled(duration <= 0 || editFingerprint == nil || captionSaving || captionSaveTask != nil)
                    Button(L10n.text("导出交付包（成片、字幕、原片工程）…")) { exportProject(delivery: true) }.disabled(compositionUnavailable || captionSaving || captionSaveTask != nil)
                }.fixedSize()
        }.disabled(editorBusy)
    }
    private var editorDelivery: some View {
        StudioActionBar {
            if exporting {
                VideoExportProgressView(progress: exportProgressAvailable ? normalizedExportProgress : nil,
                    status: exportSavePanel is NSOpenPanel ? L10n.text("选择文件…") : exportSavePanel != nil ? L10n.text("选择保存位置…") : exportOperation,
                    cancelling: cancellingExport) {
                        cancellingExport = true; exportTask?.cancel(); exportSavePanel?.cancel(nil)
                    }
            } else {
                if captionSaving || captionSaveTask != nil {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在保存编辑…")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if editSession.dirty {
                    Text(L10n.text("未保存修改")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if !imported && lastExportedURL == nil {
                    Text(copiedOriginal ? L10n.text("录屏已保存，原片已复制") : L10n.text("录屏已保存"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if let lastExportedURL, !captionSaving, captionSaveTask == nil {
                    StudioExportReceipt(url: lastExportedURL)
                }
                Spacer(minLength: 8)
                if editSaveFailed && editSession.dirty {
                    Button(L10n.text("另存编辑副本…")) { exportProject(delivery: false, recoveringDraft: true) }
                        .disabled(editorBusy)
                }
                Button(L10n.text("保存编辑")) { startCaptionSave() }.keyboardShortcut("s", modifiers: .command)
                    .disabled(duration <= 0 || editFingerprint == nil || editorBusy)
                Button(L10n.text("导出成片…")) { saveEffects() }.buttonStyle(StudioButtonStyle(primary: true, command: true)).tint(Palette.ice)
                    .disabled(compositionUnavailable || editorBusy)
            }
        }.controlSize(.small)
    }
    private var normalizedExportProgress: Double { exportProgress.isFinite ? min(max(exportProgress, 0), 1) : 0 }
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(showOriginal ? L10n.text("原片对照") : L10n.text("成片预览")).font(.system(size: 13, weight: .semibold))
                if previewUpdating { ProgressView().controlSize(.small); Text(L10n.text("更新画面…")).foregroundStyle(Palette.muted) }
                Spacer()
                Toggle(L10n.text("对照原片"), isOn: $showOriginal).toggleStyle(.switch).controlSize(.mini)
                    .disabled(duration <= 0 || previewUpdating)
            }
            NativeVideoPreview(controller: playbackController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if !showOriginal, previewPlayback != nil {
                        if let framing = effects.reframing, framing.enabled && framing.showGuides {
                            let size = effects.layout.size(source: sourceVideoSize, limit: 960)
                            VideoSafeAreaGuide(aspect: size.width / size.height, options: framing)
                                .allowsHitTesting(false)
                        }
                        cameraDragOverlay
                    }
                    if previewPlayback == nil && !showOriginal {
                        VStack(spacing: 10) {
                            if previewError == nil { ProgressView() }
                            Text(previewError == nil ? L10n.text("正在准备完整视频与摄像头画面…") : L10n.text("预览暂不可用"))
                        }.foregroundStyle(.white).padding(16).background(.black.opacity(0.7)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 8))
            if !showOriginal, !previewUpdating, effects.camera.enabled,
               let coverage = previewPlayback?.cameraCoverage, !coverage.contains(cameraPreviewSourceTime) {
                Label(L10n.text("此时段没有摄像头画面，摄像头原片可能提前结束或存在中断。"), systemImage: "video.slash")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
            if let previewError {
                HStack(alignment: .top) {
                    Label(previewError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L10n.text("重试")) { requestPreviewUpdate() }
                }.font(.system(size: 11))
            }
            HStack(spacing: 12) {
                StudioIconButton(title: playbackController.isPlaying ? L10n.text("暂停") : L10n.text("播放"), symbol: playbackController.isPlaying ? "pause.fill" : "play.fill", selected: playbackController.isPlaying) {
                    pendingSourceTime = nil; playbackController.toggle()
                }
                    .disabled(previewPlayback == nil && !showOriginal)
                    .help(playbackController.isPlaying ? L10n.text("暂停") : L10n.text("播放"))
                    .keyboardShortcut(.space, modifiers: [])
                Text("\(timecode(currentSourceTime)) / \(timecode(duration))").monospacedDigit()
                if playbackController.isSeeking { ProgressView().controlSize(.mini).help(L10n.text("正在定位画面")) }
                else if playbackController.isWaiting { ProgressView().controlSize(.mini).help(L10n.text("正在准备播放")) }
                Spacer()
            }
            Divider()
            trimControls
        }.font(.system(size: 12)).padding(StudioMetrics.contentInset).background(Palette.canvas).disabled(editorBusy)
    }
    @ViewBuilder private var cameraDragOverlay: some View {
        if cameraMaterial == .ready, effects.camera.enabled, !previewUpdating, previewError == nil,
           let playback = previewPlayback, playback.cameraCoverage?.contains(currentSourceTime) == true,
           let canvasSize = playback.item.videoComposition?.renderSize,
           let timeline = try? CameraLayoutTimeline(effects.cameraLayouts ?? [], duration: duration) {
            GeometryReader { geometry in
                let scale = min(geometry.size.width / canvasSize.width, geometry.size.height / canvasSize.height)
                let size = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
                let offset = CGPoint(x: (geometry.size.width - size.width) / 2, y: (geometry.size.height - size.height) / 2)
                let pose = timeline.pose(at: currentSourceTime, canvas: canvasSize, camera: cameraVideoSize, options: effects.camera)
                let cue = timeline.cues.first { currentSourceTime >= $0.start && currentSourceTime < $0.end }
                if pose.cameraOpacity > 0, cue == nil || cue?.mode == .pip {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .background(Color.white.opacity(0.001))
                        .frame(width: pose.camera.width * size.width, height: pose.camera.height * size.height)
                        .position(x: offset.x + pose.camera.midX * size.width, y: offset.y + (1 - pose.camera.midY) * size.height)
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if cameraDragOrigin == nil {
                                    player.pause()
                                    cameraDragOrigin = CGPoint(x: pose.camera.midX, y: pose.camera.midY)
                                }
                                guard let origin = cameraDragOrigin else { return }
                                let x = min(1 - pose.camera.width / 2, max(pose.camera.width / 2, origin.x + value.translation.width / size.width))
                                let y = min(1 - pose.camera.height / 2, max(pose.camera.height / 2, origin.y - value.translation.height / size.height))
                                if let cue, let index = effects.cameraLayouts?.firstIndex(where: { $0.id == cue.id }) {
                                    effects.cameraLayouts?[index].x = x; effects.cameraLayouts?[index].y = y
                                } else { effects.camera.x = x; effects.camera.y = y }
                            }
                            .onEnded { _ in
                                cameraDragOrigin = nil
                                if effects.reframing?.enabled == true, effects.reframing?.lockCamera != true {
                                    effects.reframing?.lockCamera = true
                                }
                            })
                        .accessibilityLabel(L10n.text("摄像头画中画，拖动调整位置"))
                        .help(L10n.text("拖动调整摄像头位置，右侧可调整大小与样式"))
                }
            }
        }
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioToolTabs(items: VideoEditorTool.allCases, selection: $tool,
                           title: { L10n.translate($0.rawValue) }, symbol: { $0.symbol }).accessibilityLabel(L10n.text("编辑工具"))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tool {
                    case .edit: editControls
                    case .picture: pictureControls
                    case .audio: audioControls
                    case .captions: captionControls
                    }
                }.font(.system(size: 13)).controlSize(.small)
                    .environment(\.videoInspectorFields, true)
                    .toggleStyle(VideoToggleStyle()).tint(Palette.ice)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(StudioMetrics.contentInset)
            }.scrollBounceBehavior(.basedOnSize).disabled(exporting || captionSaving || captionSaveTask != nil)
        }.background(Palette.paper)
    }
    private var trimControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoTrimTimeline(start: $trimStart, end: $trimEnd, duration: duration, position: currentSourceTime,
                              trimSeek: { seekSource($0, preparingEdit: true) }) { seekSource($0) }
            HStack {
                Button(L10n.text("重置范围")) { trimStart = 0; trimEnd = duration; seekSource(0, preparingEdit: true) }
                Spacer()
                Button(L10n.text("保存当前帧")) { saveFrame() }.disabled(previewPlayback == nil || previewUpdating || previewError != nil)
            }.buttonStyle(.borderless).foregroundStyle(Palette.ice)
        }
    }
    private var editControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoInspectorGroup(L10n.text("裁剪范围"), initiallyExpanded: true) {
                VideoField(title: L10n.text("起点（秒）")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.text("起点"), value: Binding(get: { trimStart }, set: { value in
                            guard value.isFinite else { return }
                            trimStart = min(max(0, value), max(0, trimEnd - 0.1))
                            seekSource(trimStart, preparingEdit: true)
                        }), format: .number.precision(.fractionLength(0...2)))
                            .monospacedDigit()
                        Button(L10n.text("设为当前位置")) { trimStart = min(max(0, currentSourceTime), max(0, trimEnd - 0.1)) }
                            .buttonStyle(.borderless).foregroundStyle(Palette.ice)
                    }
                }
                VideoField(title: L10n.text("终点（秒）")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.text("终点"), value: Binding(get: { trimEnd }, set: { value in
                            guard value.isFinite else { return }
                            trimEnd = min(duration, max(trimStart + 0.1, value))
                            seekSource(max(trimStart, trimEnd - 1.0 / 30), preparingEdit: true)
                        }), format: .number.precision(.fractionLength(0...2)))
                            .monospacedDigit()
                        Button(L10n.text("设为当前位置")) { trimEnd = min(duration, max(trimStart + 0.1, currentSourceTime)) }
                            .buttonStyle(.borderless).foregroundStyle(Palette.ice)
                    }
                }
            }
            VideoAdvancedEditView(edit: Binding(get: { effects.edit ?? VideoAdvancedEdit() }, set: { effects.edit = $0 }), duration: duration,
                                  currentTime: { currentSourceTime }) { seekSource($0) }
            VideoPrivacyEditor(cues: Binding(get: { effects.privacy ?? [] }, set: { effects.privacy = $0 }), video: url, duration: duration,
                               canvasSize: effects.layout.size(source: sourceVideoSize), currentTime: { currentSourceTime }) { seekSource($0) }
        }
    }
    private var motionAvailability: VideoMotionAvailability {
        .init(options: effects, lenses: lenses, hasInteractions: hasInteractions, cameraReady: cameraMaterial == .ready)
    }
    private var pictureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoCanvasControls(options: $effects)
            VideoInspectorGroup(L10n.text("摄像头"), expanded: $cameraExpanded, grid: false) {
                if cameraOutputUnavailable {
                    Label(L10n.text("摄像头素材不可用"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                VideoControlGrid {
                    if cameraMaterial == .ready || cameraOutputUnavailable {
                        Toggle(L10n.text("显示摄像头"), isOn: $effects.camera.enabled)
                    }
                    if cameraMaterial == .ready && effects.camera.enabled {
                        VideoField(title: L10n.text("形状")) { Picker(L10n.text("形状"), selection: $effects.camera.shape) {
                            ForEach(CameraOverlayShape.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu) }
                        Toggle(L10n.text("镜像"), isOn: $effects.camera.mirrored)
                        InspectorSlider(title: L10n.text("大小"), value: $effects.camera.width, range: 0.1...0.45, scale: 100, unit: "%")
                    }
                    VideoField(title: L10n.text("摄像头素材")) {
                        Button(cameraMaterial == .ready ? L10n.text("更换视频…") : L10n.text("导入视频…")) { importCamera() }
                            .disabled(!previewReady || editorBusy)
                    }
                }
            }
            if hasInteractions {
                VideoInspectorGroup(L10n.text("点击与快捷键")) {
                    Toggle(L10n.text("点击光圈"), isOn: $effects.clicks)
                    Toggle(L10n.text("显示快捷键"), isOn: $effects.shortcuts)
                }
            }
            if motionAvailability.manualZoom {
                VideoZoomControls(options: $effects, lenses: $lenses, x: $lensX, y: $lensY,
                    zoom: $lensZoom, lensDuration: $lensDuration, hasInteractions: hasInteractions,
                    trimStart: trimStart, trimEnd: trimEnd, currentTime: { currentSourceTime })
            }
            if motionAvailability.optics {
                RecordingOpticsEditor(options: Binding(get: { effects.optics ?? .init() }, set: { effects.optics = $0 }),
                    screenMotionAvailable: motionAvailability.screenOptics, cameraMotionAvailable: motionAvailability.cameraOptics)
            }
            if hasEditableCursor {
                RecordingCursorEditor(options: Binding(get: { effects.cursor ?? .init() }, set: { effects.cursor = $0 }), currentTime: { currentSourceTime }, duration: duration, available: true)
            }
            VideoQualityEditor(options: Binding(get: { effects.quality ?? .init() }, set: { effects.quality = $0 }))
            VideoReframingEditor(options: Binding(get: { effects.reframing ?? .init() }, set: { effects.reframing = $0 }))
            if cameraMaterial == .ready && effects.camera.enabled {
                CameraLayoutEditor(cues: Binding(get: { effects.cameraLayouts ?? [] }, set: { effects.cameraLayouts = $0 }), currentTime: { currentSourceTime }, duration: duration, defaults: effects.camera)
                CameraAutomationEditor(options: Binding(get: { effects.cameraAutomation ?? .init() }, set: { effects.cameraAutomation = $0 }), currentTime: { currentSourceTime }, duration: duration)
            }
        }
    }
    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !audioSources.isEmpty {
                if audioSources.count > 1 {
                    VideoInspectorGroup(L10n.text("录制声音"), initiallyExpanded: true) {
                        ForEach(audioSources) { source in
                            InspectorSlider(title: source.title, value: Binding(get: {
                                Double(effects.audio.sourceVolumes?[source.id] ?? 1)
                            }, set: { value in
                                var volumes = effects.audio.sourceVolumes ?? [:]
                                volumes[source.id] = Float(value); effects.audio.sourceVolumes = volumes
                            }), range: 0...2, scale: 100, unit: "%")
                        }
                    }
                }
                VideoInspectorGroup(L10n.text("整体音量"), initiallyExpanded: true) {
                    InspectorSlider(title: audioSources.count > 1 ? L10n.text("混合音量") : audioSources.first?.title ?? L10n.text("原片音量"), value: Binding(get: { Double(effects.audio.volume) }, set: { effects.audio.volume = Float($0) }), range: 0...2, scale: 100, unit: "%")
                    Toggle(L10n.text("自动音量"), isOn: $effects.audio.normalize)
                        .onChange(of: effects.audio.normalize) { _, enabled in
                            if enabled, effects.audio.voice?.loudness == true { effects.audio.voice?.loudness = false }
                        }
                    InspectorSlider(title: L10n.text("淡入淡出"), value: $effects.audio.fade, range: 0...1, unit: L10n.text(" 秒"), decimals: 1)
                }
                VideoInspectorGroup(L10n.text("降噪")) {
                    Toggle(L10n.text("低频降噪"), isOn: $effects.audio.cleanup)
                    Toggle(L10n.text("底噪抑制"), isOn: Binding(get: { effects.audio.spectralReduction ?? false }, set: { effects.audio.spectralReduction = $0 }))
                    if effects.audio.spectralReduction == true {
                        InspectorSlider(title: L10n.text("抑制强度"), value: Binding(get: { Double(effects.audio.reductionStrength ?? 0.75) }, set: { effects.audio.reductionStrength = Float($0) }), range: 0...1, scale: 100, unit: "%")
                    }
                }
                VoiceAudioEditor(options: Binding(get: { effects.audio.voice ?? .init() }, set: { effects.audio.voice = $0 }))
                    .onChange(of: effects.audio.voice?.loudness) { _, enabled in
                        if enabled == true { effects.audio.normalize = false }
                    }
            } else {
                Label(L10n.text("此视频没有录制声音"), systemImage: "speaker.slash").foregroundStyle(Palette.muted)
            }
            VideoMusicEditor(edit: Binding(get: { effects.edit ?? .init() }, set: { effects.edit = $0 }))
        }
    }
    private var captionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !audioSources.isEmpty || speechTask != nil {
                VideoInspectorGroup(L10n.text("语音转写"), initiallyExpanded: true) {
                    VideoField(title: L10n.text("转写引擎")) {
                        Picker(L10n.text("转写引擎"), selection: $localSpeech) {
                            Text(L10n.text("本地转写")).tag(true)
                            if VideoTranscript.systemTranscriptionAvailable { Text(L10n.text("系统转写")).tag(false) }
                        }.disabled(speechTask != nil)
                    }
                    VideoField(title: L10n.text("语言")) {
                        Picker(L10n.text("语言"), selection: $speechLanguage) {
                            Text(L10n.text("中文")).tag("zh-CN"); Text("English").tag("en-US")
                            if localSpeech {
                                Text(L10n.text("自动")).tag("auto"); Text("日本語").tag("ja-JP"); Text("한국어").tag("ko-KR")
                                Text("Français").tag("fr-FR"); Text("Deutsch").tag("de-DE"); Text("Español").tag("es-ES")
                            }
                        }.disabled(speechTask != nil)
                    }
                    if localSpeech {
                        VideoField(title: L10n.text("模型")) {
                            Picker(L10n.text("模型"), selection: $speechTier) { ForEach(LocalSpeechTier.allCases) { Text($0.title).tag($0) } }
                                .disabled(speechTask != nil)
                        }
                        VideoField(title: L10n.text("模型管理")) { Button(L10n.text("管理模型…")) { showSpeechModels = true } }
                    }
                    VideoField(title: L10n.text("语音转写")) {
                        Button(speechTask == nil ? L10n.text("开始转写") : L10n.text("取消转写")) {
                            if let task = speechTask { task.cancel() } else { transcribe() }
                        }
                    }
                }
            }
            VideoInspectorGroup(L10n.text("字幕"), initiallyExpanded: true) {
                if !captions.isEmpty { Toggle(L10n.text("显示字幕"), isOn: $effects.burnCaptions) }
                VideoField(title: L10n.text("导入字幕")) { Button(L10n.text("导入 SRT…")) { importCaptions() }.disabled(speechTask != nil) }
                if !captions.isEmpty {
                    VideoField(title: L10n.text("导出字幕")) { Button(L10n.text("导出 SRT…")) { saveCaptions() } }
                }
            }
            if let speechStatus { Text(speechStatus).foregroundStyle(Palette.muted) }
            if !captions.isEmpty {
                TranscriptEditor(captions: $captions, edit: Binding(get: { effects.edit ?? .init() }, set: { effects.edit = $0 }), duration: duration,
                    currentTime: { currentSourceTime }, seek: { time in seekSource(time) }, save: { startCaptionSave() })
                    .disabled(speechTask != nil || captionSaving || editFingerprint == nil)
            }
        }.sheet(isPresented: $showSpeechModels) { LocalSpeechModelsView() }
    }
    private var currentSourceTime: Double {
        let time = playbackController.position
        if !showOriginal, let playback = previewPlayback {
            return RecordingEffectsExporter.sourceTime(time, plan: playback.plan)
        }
        return time
    }
    private var cameraPreviewSourceTime: Double {
        guard !showOriginal, let playback = previewPlayback else { return currentSourceTime }
        // The end time is exclusive. The player still displays the final frame
        // there; compare coverage at that frame rather than reporting a gap
        // because camera and screen duration differ by a few microseconds.
        let time = min(playbackController.position, max(0, playback.plan.duration - 1.0 / 600))
        return RecordingEffectsExporter.sourceTime(time, plan: playback.plan)
    }
    private func seekSource(_ time: Double, preparingEdit: Bool = false) {
        pendingSourceTime = preparingEdit || previewUpdating ? time : nil
        let position = !showOriginal ? previewPlayback?.plan.editedTime(for: time) ?? time : time
        playbackController.seek(position)
    }
    private func effectsChanged(from old: RecordingEffectsOptions, to new: RecordingEffectsOptions) {
        // Audio gain/fades do not alter video frames or the source timeline.
        var audioOnly = old
        audioOnly.audio.volume = new.audio.volume; audioOnly.audio.fade = new.audio.fade
        audioOnly.audio.sourceVolumes = new.audio.sourceVolumes
        if previewReady, !previewUpdating, previewError == nil, audioOnly == new,
           !old.audio.needsProcessing, !new.audio.needsProcessing,
           let playback = previewPlayback {
            do {
                try playback.updateAudio(new.audio)
                return
            } catch { requestPreviewUpdate(); return }
        }
        var live = old
        live.background = new.background; live.padding = new.padding; live.style = new.style
        live.cornerRadius = new.cornerRadius; live.fillsCanvas = new.fillsCanvas
        live.clicks = new.clicks; live.smartZoom = new.smartZoom; live.zoom = new.zoom; live.shortcuts = new.shortcuts
        live.camera.x = new.camera.x; live.camera.y = new.camera.y
        live.camera.width = new.camera.width; live.camera.mirrored = new.camera.mirrored
        live.cameraLayouts = new.cameraLayouts
        guard previewReady, !previewUpdating, previewError == nil, live == new, let playback = previewPlayback else {
            requestPreviewUpdate(); return
        }
        do {
            var options = new; options.captions = captions; options.lenses = lenses; options.maximumDimension = 1280
            try playback.state.update(options, duration: duration)
            // Running playback reads the new state on its next frame.
            // A paused frame needs a fresh composition to invalidate AVFoundation's cache.
            if player.rate == 0 || showOriginal { liveFrameRevision += 1 }
        } catch { requestPreviewUpdate() }
    }
    private func refreshLiveFrame() async {
        guard liveFrameRevision > 0, !previewUpdating, let playback = previewPlayback else { return }
        let revision = liveFrameRevision
        do {
            let worker = Task.detached(priority: .userInitiated) { try await playback.renderer.refresh() }
            let composition = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard revision == liveFrameRevision, previewPlayback === playback, !previewUpdating else { return }
            let item = AVPlayerItem(asset: playback.renderer.asset)
            item.videoComposition = composition.value; item.audioMix = playback.item.audioMix
            if !showOriginal {
                try await playbackController.present(item, at: { playbackController.position }, onCommit: {
                    item.audioMix = playback.item.audioMix
                    playback.useItem(item)
                })
            } else { playback.useItem(item) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { requestPreviewUpdate() }
        }
    }
    private func requestPreviewUpdate() {
        guard previewReady else { return }
        previewRevision += 1
        previewUpdating = true; previewError = nil
        liveFrameRevision += 1
    }
    private func switchPreviewMode() async {
        guard previewReady, showOriginal || previewPlayback != nil else { return }
        let original = showOriginal
        let item = original ? AVPlayerItem(url: url) : previewPlayback!.item
        do {
            try await playbackController.present(item, at: {
                let time = player.currentTime().seconds
                return original
                    ? previewPlayback.map { RecordingEffectsExporter.sourceTime(time, plan: $0.plan) } ?? 0
                    : previewPlayback?.plan.editedTime(for: time) ?? 0
            }, onCommit: { pendingSourceTime = nil })
        } catch is CancellationError {
        } catch { if !Task.isCancelled { previewError = error.localizedDescription } }
    }
    private func updatePreview() async {
        guard previewReady else { return }
        guard duration > 0.1, editFingerprint != nil else {
            previewUpdating = false
            previewError = editFingerprint == nil ? L10n.text("工程文件未能读取，无法应用编辑设置。") : L10n.text("没有足够的视频画面可供编辑。")
            return
        }
        let revision = previewRevision
        defer { if previewRevision == revision { previewUpdating = false } }
        do {
            try await Task.sleep(for: .milliseconds(120))
            guard !cameraOutputUnavailable else { throw CaptureError.message(cameraMaterial.detail) }
            var options = effects
            options.captions = captions; options.lenses = lenses; options.maximumDimension = 1280
            let input = url, start = trimStart, end = trimEnd
            let worker = Task.detached(priority: .userInitiated) {
                try await RecordingEffectsExporter.playback(input, options: options, start: start, end: end)
            }
            let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard previewReady, revision == previewRevision else { return }
            if !showOriginal {
                try await playbackController.present(prepared.item, at: {
                    prepared.plan.editedTime(for: pendingSourceTime ?? currentSourceTime)
                }, onCommit: {
                    pendingSourceTime = nil; previewPlayback = prepared
                })
            } else { pendingSourceTime = nil; previewPlayback = prepared }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, revision == previewRevision else { return }
            playbackController.pause()
            previewError = L10n.text("\(error.localizedDescription)\(previewPlayback == nil ? "" : L10n.text(" 当前保留上次画面，尚未应用新设置。"))")
        }
    }
    private func importCamera() {
        guard previewReady, !editorBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]
        presentFilePanel(panel) { response in
            guard response == .OK, let input = panel.url else { return }
            let generation = beginExport(L10n.text("正在导入画中画…"))
            let destination = RecordingCamera.url(for: url)
            exportTask = Task {
                defer { endExport(generation) }
                do {
                    let asset = AVURLAsset(url: input)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw CaptureError.message(L10n.text("素材没有视频画面。"))
                    }
                    // Resolve every fallible metadata read before replacing
                    // the previous material. No suspension is needed after commit.
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
                    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                        throw CaptureError.message(L10n.text("素材画面尺寸无效，未替换原素材。"))
                    }
                    try Task.checkCancellation()
                    guard generation == exportGeneration else { return }
                    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                        throw CaptureError.message(L10n.text("素材无法转换为画中画视频，未替换原素材。"))
                    }
                    try await VideoExport.export(export, to: destination, as: .mp4,
                        progress: { value in Task { @MainActor in updateExportProgress(value, generation: generation) } })
                    // A successful export has committed. Keep its UI coherent
                    // on late cancellation, but never update a closed editor.
                    guard generation == exportGeneration else { return }
                    cameraVideoSize = bounds.size
                    cameraMaterial = .ready; cameraExpanded = true
                    effects.camera.enabled = true; effects.camera.mirrored = false
                    requestPreviewUpdate(); report(L10n.text("画中画素材已导入，可在画面中拖动调整位置。"), generation: generation)
                } catch { report(Task.isCancelled ? L10n.text("导入已取消") : L10n.text("画中画导入失败：\(error.localizedDescription)"), kind: Task.isCancelled ? .information : .error, generation: generation) }
            }
        }
    }
    private func transcribe() {
        speechStatus = L10n.text("正在准备模型与转写…")
        let useLocal = localSpeech, tier = speechTier, locale = speechLanguage, input = url
        speechTask = Task {
            defer { speechTask = nil }
            do {
                let result = useLocal ? try await LocalSpeechTranscriber.transcribe(input, tier: tier, language: locale == "auto" ? "auto" : String(locale.prefix(2))) : try await VideoTranscript.transcribe(input, localeIdentifier: locale)
                try Task.checkCancellation()
                try await persistCaptionProject(result)
                speechStatus = result.isEmpty ? L10n.text("未识别到语音，可导入 SRT。") : L10n.text("转写完成，可以编辑字幕或取消勾选句子。")
            } catch is CancellationError { speechStatus = L10n.text("转写已取消") }
            catch { speechStatus = L10n.text("转写失败：\(error.localizedDescription)") }
        }
    }
    private func importCaptions() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, .plainText]; panel.allowsMultipleSelection = false
        presentFilePanel(panel) { response in
            guard response == .OK, let input = panel.url else { return }
            guard captionSaveTask == nil else { return }
            captionSaveTask = Task {
                defer { captionSaveTask = nil }
                do {
                    let worker = Task.detached(priority: .utility) {
                        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size < 5_000_000 else { throw CaptureError.message(L10n.text("字幕文件过大。")) }
                        try Task.checkCancellation(); return try VideoTranscript.parseSRT(String(contentsOf: input, encoding: .utf8))
                    }
                    let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    try await persistCaptionProject(result); speechStatus = L10n.text("字幕已导入")
                } catch { if !Task.isCancelled { report(error.localizedDescription, kind: .error) } }
            }
        }
    }
    private func startCaptionSave(closeAfter: Bool = false) {
        guard !editorBusy else { return }
        captionSaveTask = Task {
            defer { captionSaveTask = nil }
            do {
                try await persistCaptionProject()
                if !Task.isCancelled {
                    report(L10n.text("编辑已保存"))
                    if closeAfter, !editSession.dirty { editSession.window?.close() }
                }
            }
            catch {
                if !Task.isCancelled { editSaveFailed = true; report(error.localizedDescription, kind: .error) }
            }
        }
    }
    private func persistCaptionProject(_ replacement: [CaptionSegment]? = nil) async throws {
        guard !captionSaving, let expected = editFingerprint else { throw CaptureError.message(L10n.text("工程尚未就绪或正在保存，请重新打开后重试。")) }
        try Task.checkCancellation()
        let rows = replacement ?? captions
        let savedState = VideoEditState(effects: effects, captions: rows, lenses: lenses, start: trimStart, end: trimEnd)
        var options = effects; options.captions = rows; options.lenses = lenses
        let snapshot = RecordingEditSnapshot(captions: rows, studio: .init(lenses: lenses, effects: options, trimStart: trimStart, trimEnd: trimEnd)), input = url, seconds = duration
        captionSaving = true; defer { captionSaving = false }
        let worker = Task.detached(priority: .utility) {
            guard savedState.start.isFinite, savedState.end.isFinite,
                  savedState.start >= 0, savedState.end > savedState.start,
                  savedState.end <= seconds + 0.001 else {
                throw CaptureError.message(L10n.text("裁剪范围无效，请在原片时长内设置起点和终点。"))
            }
            guard rows.allSatisfy({ $0.end <= seconds + 0.001 }) else { throw CaptureError.message(L10n.text("字幕超出原片范围。")) }
            _ = try CameraLayoutTimeline(options.cameraLayouts ?? [], duration: seconds)
            try (options.cameraAutomation ?? .init()).validate(duration: seconds)
            try (options.cursor ?? .init()).validate(duration: seconds)
            _ = try VideoPrivacyTimeline(options.privacy ?? [], duration: seconds)
            return try RecordingEditStore.save(snapshot, for: input, expected: expected)
        }
        editFingerprint = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        if !Task.isCancelled {
            if let replacement { captions = replacement }
            editSession.markSaved(savedState)
            editSaveFailed = false
        }
    }
    private func saveCaptions() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]; panel.allowsOtherFileTypes = true; panel.nameFieldStringValue = "DeskCapture.srt"
        presentFilePanel(panel) { response in
            guard response == .OK, let output = panel.url else { return }
            let rows = captions, seconds = duration, start = trimStart, end = trimEnd, sections = effects.edit?.sections ?? []
            let generation = beginExport(L10n.text("正在导出字幕…"))
            exportTask = Task {
                defer { endExport(generation) }
                do {
                    let worker = Task.detached(priority: .utility) {
                        let plan = try VideoEditPlan(duration: seconds, start: start, end: end, captions: rows, sections: sections)
                        let text = VideoTranscript.srt(plan.mappedCaptions(rows))
                        try Task.checkCancellation()
                        try CaptureImageExport.writeEncoded(Data(text.utf8), to: output)
                    }
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    completeExport(L10n.text("SRT 已保存，时间轴已同步删剪"), to: output, generation: generation)
                } catch {
                    report(Task.isCancelled ? L10n.text("字幕导出已取消") : L10n.text("字幕导出失败：\(error.localizedDescription)"),
                           kind: Task.isCancelled ? .information : .error, generation: generation)
                }
            }
        }
    }
    private func exportProject(delivery: Bool, recoveringDraft: Bool = false) {
        guard !exporting, editFingerprint != nil, !delivery || !compositionUnavailable else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = delivery ? [.folder] : [.deskVideoProject]
        panel.nameFieldStringValue = delivery ? L10n.text("DeskCapture-交付") : recoveringDraft ? L10n.text("DeskCapture-编辑副本.deskvideo") : "DeskCapture.deskvideo"
        panel.message = L10n.text("包含原片与可编辑设置；分享前请确认素材范围。已有目录不会覆盖。")
        presentFilePanel(panel) { response in
            guard response == .OK, let output = panel.url, let expected = editFingerprint else { return }
            var options = effects; options.captions = captions; options.lenses = lenses
            let input = url, snapshot = RecordingEditSnapshot(captions: captions, studio: .init(lenses: lenses, effects: options, trimStart: trimStart, trimEnd: trimEnd))
            let generation = beginExport()
            exportTask = Task {
                defer { endExport(generation) }
                do {
                    if delivery { try await ProjectDelivery.video(input, snapshot: snapshot, expected: expected, to: output, progress: { value in Task { @MainActor in updateExportProgress(value, generation: generation) } }) }
                    else {
                        let worker = Task.detached(priority: .userInitiated) {
                            // A separately named copy deliberately preserves the in-memory
                            // draft. Still reject dependencies changing during packaging.
                            let sourceFingerprint = recoveringDraft ? try RecordingEditStore.fingerprint(input) : expected
                            try PortableProject.exportVideo(input, snapshot: snapshot, expected: sourceFingerprint, to: output)
                        }
                        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    }
                    completeExport(recoveringDraft ? L10n.text("编辑副本已导出，磁盘原工程保留") : L10n.text("项目已导出，包含原始素材"), to: output, generation: generation)
                } catch { report(Task.isCancelled ? L10n.text("项目导出已取消") : L10n.text("项目导出失败：\(error.localizedDescription)"), kind: Task.isCancelled ? .information : .error, generation: generation) }
            }
        }
    }
    private func timecode(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    private func copyOriginalFile() {
        guard !editorBusy else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            report(L10n.text("原片文件未能复制，请重试或在 Finder 中显示。"), kind: .error)
            return
        }
        report(cameraMaterial == .ready ? L10n.text("屏幕原片文件已复制") : L10n.text("原片文件已复制"))
    }
    private func save(asGIF: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = asGIF ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = asGIF ? "DeskCapture.gif" : "DeskCapture.mp4"
        presentFilePanel(panel) { response in
            guard response == .OK, let output = panel.url else { return }
            let generation = beginExport()
            exportTask = Task {
                defer { endExport(generation) }
                do {
                    if asGIF { try await VideoGIFExporter.export(url, to: output, progress: { value in Task { @MainActor in updateExportProgress(value, generation: generation) } }) }
                    else {
                        let copying = Task.detached(priority: .userInitiated) {
                            try OriginalVideoCopy.copy(url, to: output)
                        }
                        try await withTaskCancellationHandler { try await copying.value } onCancel: { copying.cancel() }
                    }
                    completeExport(L10n.text("已导出"), to: output, generation: generation)
                } catch { report(Task.isCancelled ? L10n.text("导出已取消") : L10n.text("导出失败：\(error.localizedDescription)"), kind: Task.isCancelled ? .information : .error, generation: generation) }
            }
        }
    }
    private func saveTrimmed() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = L10n.text("DeskCapture 裁剪.mp4")
        presentFilePanel(panel) { response in
            guard response == .OK, let output = panel.url else { return }
            let generation = beginExport()
            let start = trimStart, end = trimEnd
            exportTask = Task {
                defer { endExport(generation) }
                do {
                    try await VideoTrimmer.export(url, to: output, start: start, end: end, progress: { value in Task { @MainActor in updateExportProgress(value, generation: generation) } })
                    completeExport(L10n.text("裁剪视频已保存"), to: output, generation: generation)
                } catch { report(Task.isCancelled ? L10n.text("裁剪已取消") : L10n.text("裁剪失败：\(error.localizedDescription)"), kind: Task.isCancelled ? .information : .error, generation: generation) }
            }
        }
    }
    private func saveEffects() {
        guard !compositionUnavailable, !exporting else { return }
        player.pause(); NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = L10n.text("DeskCapture 成片.mp4")
        presentFilePanel(panel) { response in
            guard response == .OK, let output = panel.url else { return }
            guard lenses.allSatisfy(\.valid) else { report(L10n.text("镜头的时间或焦点无效，请先修正。"), kind: .warning); return }
            var options = effects; options.captions = captions; options.lenses = lenses
            let start = trimStart, end = trimEnd
            let generation = beginExport()
            exportTask = Task {
                defer { endExport(generation) }
                do {
                    try await RecordingEffectsExporter.export(url, to: output, options: options, start: start, end: end,
                        progress: { value in Task { @MainActor in updateExportProgress(value, generation: generation) } })
                    completeExport(L10n.text("成片已保存"), to: output, generation: generation)
                } catch is CancellationError { report(L10n.text("导出已取消，原视频保留"), generation: generation) }
                catch { report(Task.isCancelled ? L10n.text("导出已取消，原视频保留") : L10n.text("成片导出失败：\(error.localizedDescription)"), kind: Task.isCancelled ? .information : .error, generation: generation) }
            }
        }
    }
    private func saveFrame() {
        guard !exporting else { return }
        guard let item = player.currentItem else { report(L10n.text("视频尚未准备好。"), kind: .warning); return }
        player.pause()
        let time = player.currentTime(), asset = item.asset, composition = item.videoComposition
        let generation = beginExport()
        exportTask = Task { [playback = previewPlayback] in
            defer { endExport(generation); withExtendedLifetime(playback) {} }
            do {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.videoComposition = composition; generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let frame = try await withTaskCancellationHandler {
                    try await generator.image(at: time).image
                } onCancel: { generator.cancelAllCGImageGeneration() }
                try Task.checkCancellation()
                guard generation == exportGeneration else { return }
                NSApp.activate(ignoringOtherApps: true)
                let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = L10n.text("DeskCapture 视频帧.png")
                exportSavePanel = panel
                let output: URL? = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
                    }
                } onCancel: { Task { @MainActor in panel.cancel(nil) } }
                if generation == exportGeneration { exportSavePanel = nil }
                try Task.checkCancellation()
                guard let output, generation == exportGeneration else { return }
                let worker = Task.detached(priority: .userInitiated) { try CaptureImageExport.png(frame, to: output) }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == exportGeneration else { return }
                completeExport(L10n.text("视频帧已保存"), to: output, generation: generation)
            } catch {
                guard generation == exportGeneration else { return }
                report(Task.isCancelled ? L10n.text("视频帧导出已取消，原视频保留。") : L10n.text("视频帧导出失败：\(error.localizedDescription)"),
                       kind: Task.isCancelled ? .information : .error, generation: generation)
            }
        }
    }
    /// Own the chooser as well as the encoder. A dismissed editor must never
    /// start new work from a delayed AppKit completion handler.
    private func presentFilePanel(_ panel: NSSavePanel,
                                    completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !exporting else { return }
        let generation = beginExport()
        exportSavePanel = panel
        panel.begin { response in
            guard generation == exportGeneration else { return }
            let cancelled = cancellingExport
            endExport(generation)
            guard !cancelled, response == .OK else { return }
            completion(response)
        }
    }
    private func beginExport(_ operation: String = L10n.text("正在处理…")) -> UUID {
        exportOperation = operation
        let generation = UUID(); exportGeneration = generation
        exporting = true; cancellingExport = false; exportProgress = 0; exportProgressAvailable = false; exportSavePanel = nil; message = nil
        return generation
    }
    private func endExport(_ generation: UUID) {
        guard generation == exportGeneration else { return }
        exporting = false; cancellingExport = false; exportTask = nil; exportSavePanel = nil
    }
    private func updateExportProgress(_ value: Double, generation: UUID) {
        guard generation == exportGeneration, exporting, !cancellingExport, value.isFinite else { return }
        exportProgressAvailable = true; exportProgress = min(max(value, 0), 1)
    }
    private func report(_ text: String, kind: StudioMessageKind = .information, generation: UUID? = nil) {
        if let generation, generation != exportGeneration { return }
        message = text; messageKind = kind
    }
    private func completeExport(_ text: String, to output: URL, generation: UUID) {
        // Called only after the exporter returns from its file commit. A late
        // cancellation cannot undo that commit; a closed editor changes generation.
        guard generation == exportGeneration else { return }
        lastExportedURL = output
        report(text, generation: generation)
    }
}

struct NativeVideoPreview: NSViewRepresentable {
    let controller: VideoEditorPlaybackController
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = controller.presentationLayer
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

enum VideoTrimmer {
    static func range(start: Double, end: Double, duration: Double) throws -> CMTimeRange {
        guard duration.isFinite, start.isFinite, end.isFinite, start >= 0, end > start + 0.09, end <= duration + 0.01 else {
            throw CaptureError.message(L10n.text("裁剪范围无效。"))
        }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           duration: CMTime(seconds: end - start, preferredTimescale: 600))
    }
    static func export(_ source: URL, to output: URL, start: Double, end: Double, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: source)
        defer { withExtendedLifetime(asset) {} }
        let duration = try await asset.load(.duration).seconds
        let selected = try range(start: start, end: end, duration: duration)
        let composition = AVMutableComposition()
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let videoOutput = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.message(L10n.text("录屏缺少视频画面。"))
        }
        try await RecordingVideoTimeline.append(video, sourceDuration: CMTime(seconds: duration, preferredTimescale: 600),
                                                to: videoOutput, at: .zero)
        videoOutput.preferredTransform = try await video.load(.preferredTransform)
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            guard let audioOutput = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let available = CMTimeRangeGetIntersection(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)), otherRange: try await audio.load(.timeRange))
            if available.duration > .zero { try audioOutput.insertTimeRange(available, of: audio, at: available.start) }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError.message(L10n.text("无法创建视频裁剪任务。"))
        }
        session.timeRange = selected
        try await VideoExport.export(session, to: output, as: .mp4, progress: progress)
    }
}

enum RecordingVideoTimeline {
    static func append(_ source: AVAssetTrack, sourceDuration: CMTime,
                       to destination: AVMutableCompositionTrack, at offset: CMTime, sourceStart: CMTime? = nil) async throws {
        let videoRange = try await source.load(.timeRange)
        let start = max(videoRange.start, sourceStart ?? videoRange.start)
        let rate = max(1, Double(try await source.load(.nominalFrameRate)))
        if start >= videoRange.end && videoRange.duration > .zero {
            let tail = min(videoRange.duration, CMTime(seconds: 1 / rate, preferredTimescale: 600))
            try destination.insertTimeRange(CMTimeRange(start: videoRange.end - tail, duration: tail), of: source, at: offset)
            destination.scaleTimeRange(CMTimeRange(start: offset, duration: tail), toDuration: sourceDuration)
            return
        }
        let available = min(videoRange.end - start, sourceDuration)
        guard available > .zero else { throw CaptureError.message(L10n.text("录屏没有可用的视频帧。")) }
        try destination.insertTimeRange(CMTimeRange(start: start, duration: available), of: source, at: offset)
        let gap = sourceDuration - available
        guard gap > .zero else { return }
        let tail = min(available, CMTime(seconds: 1 / rate, preferredTimescale: 600))
        let fillStart = offset + available
        try destination.insertTimeRange(CMTimeRange(start: start + available - tail, duration: tail),
                                        of: source, at: fillStart)
        destination.scaleTimeRange(CMTimeRange(start: fillStart, duration: tail), toDuration: gap)
    }
}

struct BeautifyResultView: View {
    let source: CGImage
    let copy: (CGImage) -> Void
    let save: (CGImage) -> Void
    let close: () -> Void
    var initialWatermark: ImageWatermark? = nil
    @State private var initializedWatermark = false
    var chooseSource: (() -> Void)? = nil
    var pasteSource: (() -> Void)? = nil
    var isPresented: () -> Bool = { true }
    var deliveryStateChanged: (Bool) -> Void = { _ in }
    var output = ImageDeliveryState()
    var cancelOutput: () -> Void = {}
    var dismissOutputError: () -> Void = {}
    @State private var watermark = ImageWatermark()
    @State private var style: BeautifyStyle = .aurora
    @State private var paddingPercent = 0.09
    @State private var roundness = 0.27
    @State private var layout: BeautifyLayout = .original
    @State private var customBackground: CGImage?
    @State private var backgroundRevision = UUID()
    @State private var presetName = L10n.text("我的样式")
    @State private var savingPreset = false
    @StateObject private var presets = BeautifyPresetStore()
    @State private var result: CGImage?
    @State private var error: String?
    @State private var renderer = BeautifyPreviewRenderer()
    @State private var renderedKey: PreviewKey?
    @State private var backgroundTask: Task<Void, Never>?
    @State private var backgroundPanel: NSOpenPanel?
    @State private var backgroundRequest = UUID()
    @State private var backgroundLoading = false
    @State private var beautifierVisible = true
    @State private var deliveryTask: Task<Void, Never>?
    @State private var deliveryRequest = UUID()
    @State private var preparingDelivery = false
    @State private var deliveryError: String?
    private struct PreviewKey: Hashable {
        let style: String; let layout: String; let padding: Double; let roundness: Double; let background: UUID; let watermark: ImageWatermark
    }
    private var previewKey: PreviewKey {
        .init(style: style.rawValue, layout: layout.rawValue, padding: paddingPercent, roundness: roundness, background: backgroundRevision, watermark: watermark)
    }
    private var currentResult: Bool { result != nil && renderedKey == previewKey && !backgroundLoading }
    private var previewPending: Bool { (renderedKey != previewKey && error == nil) || backgroundLoading }
    private var outputGeometry: CaptureBeautifier.CanvasGeometry? {
        try? CaptureBeautifier.geometry(width: source.width, height: source.height, paddingPercent: paddingPercent, layout: layout)
    }
    private var selectedLook: BeautifyLook? {
        guard customBackground == nil else { return nil }
        return BeautifyLook.allCases.first { $0.matches(style: style, padding: paddingPercent, roundness: roundness) }
    }
    var body: some View {
        StudioWorkspace(title: L10n.text("图片美化"), symbol: "sparkles") {
            if let chooseSource { Button(L10n.text("更换图片…"), action: chooseSource).disabled(preparingDelivery || output.busy) }
            if let pasteSource {
                StudioIconButton(title: L10n.text("从剪贴板更换图片"), symbol: "clipboard", action: pasteSource).disabled(preparingDelivery || output.busy)
            }
        } preview: {
            ZStack {
                if let result {
                    Image(decorative: result, scale: 1).resizable().scaledToFit()
                } else if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else { ProgressView(L10n.text("正在生成预览…")) }
            }.overlay(alignment: .topTrailing) {
                if previewPending, result != nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(backgroundLoading ? L10n.text("正在载入背景…") : L10n.text("正在更新预览…")).font(.system(size: 12)) }
                        .padding(10).background(Palette.paper, in: RoundedRectangle(cornerRadius: 8)).padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = output.error {
                    StudioMessage(text: error, kind: .error, dismiss: dismissOutputError).padding(12)
                }
            }
        } inspector: {
            if !BeautifyLook.available(for: source, layout: layout).isEmpty {
                InspectorGroup(L10n.text("风格"), initiallyExpanded: true) {
                    BeautifyLookPicker(source: source, layout: layout, selected: selectedLook) { look in
                        cancelBackgroundLoad(); cancelDelivery()
                        style = look.style; paddingPercent = look.padding; roundness = look.roundness
                        customBackground = nil; backgroundRevision = UUID()
                    }
                }.disabled(output.busy)
            }
            InspectorGroup(L10n.text("画布"), initiallyExpanded: BeautifyLook.available(for: source, layout: layout).isEmpty) {
                InspectorField(title: L10n.text("比例")) {
                    Picker(L10n.text("比例"), selection: $layout) { ForEach(BeautifyLayout.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
                InspectorSlider(title: L10n.text("留白"), value: $paddingPercent, range: 0...0.35, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("圆角"), value: $roundness, range: 0...1, scale: 100, unit: "%")
            }.disabled(output.busy)
            InspectorGroup(L10n.text("背景")) {
                BackgroundSwatches(selection: Binding(get: { style }, set: { value in
                    cancelBackgroundLoad(); style = value; customBackground = nil; backgroundRevision = UUID()
                }), showsSelection: customBackground == nil)
                Button(L10n.text("导入背景图片…"), action: chooseBackground)
                    .disabled(backgroundLoading || preparingDelivery || backgroundPanel != nil)
                if customBackground != nil { Button(L10n.text("恢复渐变背景")) { cancelBackgroundLoad(); customBackground = nil; backgroundRevision = UUID() } }
                if backgroundLoading { Button(L10n.text("取消载入背景")) { cancelBackgroundLoad() } }
            }.disabled(output.busy)
            InspectorGroup(L10n.text("水印"), initiallyExpanded: initialWatermark?.active == true) {
                Toggle(L10n.text("添加平铺水印"), isOn: $watermark.enabled).toggleStyle(InspectorToggleStyle())
                if watermark.enabled {
                    WatermarkFields(value: $watermark)
                    if watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(L10n.text("输入文字后生效"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
            }.disabled(output.busy)
            InspectorGroup(L10n.text("我的预设")) {
                StudioMenu(L10n.text("载入预设")) {
                    ForEach(presets.presets) { preset in
                        Button(preset.name) { loadPreset(preset) }
                    }
                }.disabled(presets.presets.isEmpty)
                InspectorField(title: L10n.text("预设名称")) { TextField(L10n.text("名称"), text: $presetName) }
                Button(savingPreset ? L10n.text("保存中…") : L10n.text("保存预设")) {
                    let name = presetName, selected = style, selectedLayout = layout, padding = paddingPercent, radius = roundness, background = customBackground
                    savingPreset = true
                    Task {
                        do { try await presets.save(name: name, style: selected, layout: selectedLayout, padding: padding, roundness: radius, background: background); error = nil }
                        catch { self.error = error.localizedDescription }
                        savingPreset = false
                    }
                }.disabled(savingPreset || backgroundLoading)
                if !presets.presets.isEmpty {
                    StudioMenu(L10n.text("移除预设")) {
                        ForEach(presets.presets) { preset in Button(preset.name) { do { try presets.remove(preset) } catch { self.error = error.localizedDescription } } }
                    }
                }
            }.disabled(output.busy)
            if let error, result != nil {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let deliveryError {
                Label(deliveryError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } actions: {
            if preparingDelivery {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在准备原尺寸图片…")).foregroundStyle(Palette.muted)
                Button(L10n.text("取消"), action: cancelDelivery)
            } else if output.hasResult {
                StudioImageDeliveryStatus(state: output, cancel: cancelOutput)
            } else if currentResult, let outputGeometry {
                Text("\(outputGeometry.width) × \(outputGeometry.height) px").monospacedDigit().foregroundStyle(Palette.muted)
            }
            else if previewPending { Text(L10n.text("正在更新预览…")).foregroundStyle(Palette.muted) }
            Spacer()
            Button { prepareDelivery(save) } label: {
                Text(L10n.text("保存副本…")).padding(.horizontal, 12).frame(minHeight: 32)
            }.buttonStyle(StudioButtonStyle()).disabled(!currentResult || preparingDelivery || output.busy)
                .keyboardShortcut("s", modifiers: .command)
            Button { prepareDelivery(copy) } label: {
                Text(L10n.text("复制图片")).padding(.horizontal, 12).frame(minHeight: 32)
            }.buttonStyle(StudioButtonStyle(primary: true)).disabled(!currentResult || preparingDelivery || output.busy)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
            .task(id: previewKey) {
                let key = previewKey
                let selected = style, selectedLayout = layout, padding = paddingPercent, radius = roundness, background = customBackground
                let workerRenderer = renderer, input = source, selectedWatermark = watermark
                error = nil
                do {
                    try await Task.sleep(for: .milliseconds(140))
                    let worker = Task.detached(priority: .userInitiated) {
                        try await workerRenderer.render(input, style: selected, layout: selectedLayout, padding: padding,
                                                  roundness: radius, background: background, watermark: selectedWatermark)
                    }
                    let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, key == previewKey, beautifierVisible, isPresented() else { return }
                    result = image; renderedKey = key
                } catch is CancellationError { }
                catch { if !Task.isCancelled, key == previewKey, beautifierVisible, isPresented() { self.error = error.localizedDescription } }
            }
            .onChange(of: previewKey) { _, _ in cancelBackgroundPanel(); cancelBackgroundLoad(); cancelDelivery(); deliveryError = nil }
            .onAppear {
                beautifierVisible = true
                if !initializedWatermark {
                    initializedWatermark = true
                    if let initialWatermark { watermark = initialWatermark }
                }
            }
            .onDisappear { beautifierVisible = false; cancelBackgroundPanel(); cancelBackgroundLoad(); cancelDelivery() }
    }
    private func cancelDelivery() {
        deliveryRequest = UUID(); deliveryTask?.cancel(); deliveryTask = nil
        preparingDelivery = false; deliveryStateChanged(false)
    }
    private func prepareDelivery(_ deliver: @escaping (CGImage) -> Void) {
        guard currentResult, !preparingDelivery, !output.busy, beautifierVisible, isPresented() else { return }
        let key = previewKey, token = UUID(), input = source, workerRenderer = renderer, selectedWatermark = watermark
        let selected = style, selectedLayout = layout, padding = paddingPercent, radius = roundness, background = customBackground
        deliveryRequest = token; preparingDelivery = true; deliveryError = nil; deliveryStateChanged(true)
        deliveryTask = Task { @MainActor in
            defer {
                if deliveryRequest == token {
                    deliveryTask = nil; preparingDelivery = false; deliveryStateChanged(false)
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await workerRenderer.render(input, style: selected, layout: selectedLayout,
                        padding: padding, roundness: radius, background: background, fullResolution: true, watermark: selectedWatermark)
                }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, deliveryRequest == token, key == previewKey,
                      !backgroundLoading, beautifierVisible, isPresented() else { return }
                deliver(image)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, deliveryRequest == token, key == previewKey, beautifierVisible, isPresented() else { return }
                deliveryError = error.localizedDescription
            }
        }
    }
    private func cancelBackgroundLoad() {
        backgroundRequest = UUID(); backgroundTask?.cancel(); backgroundTask = nil; backgroundLoading = false
    }
    private func loadPreset(_ preset: BeautifyPreset) {
        beginBackgroundLoad {
            let image = try await presets.loadBackground(for: preset)
            return (preset.style, preset.layout, min(0.35, max(0, preset.padding)), min(1, max(0, preset.roundness)), image)
        }
    }
    private func beginBackgroundLoad(_ work: @escaping @MainActor () async throws -> (BeautifyStyle, BeautifyLayout, Double, Double, CGImage?)) {
        cancelDelivery(); deliveryError = nil
        cancelBackgroundLoad()
        let request = UUID(); backgroundRequest = request; backgroundLoading = true; error = nil
        backgroundTask = Task {
            defer { if backgroundRequest == request { backgroundTask = nil; backgroundLoading = false } }
            do {
                let (newStyle, newLayout, padding, radius, image) = try await work()
                guard !Task.isCancelled, backgroundRequest == request else { return }
                style = newStyle; layout = newLayout; paddingPercent = padding; roundness = radius
                customBackground = image; backgroundRevision = UUID()
            } catch {
                guard !Task.isCancelled, backgroundRequest == request else { return }; self.error = error.localizedDescription
            }
        }
    }
    private func cancelBackgroundPanel() {
        let panel = backgroundPanel
        backgroundPanel = nil
        panel?.cancel(nil)
    }
    private func chooseBackground() {
        guard backgroundPanel == nil, !backgroundLoading, !preparingDelivery, !output.busy,
              beautifierVisible, isPresented() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        backgroundPanel = panel
        panel.begin { response in
            guard backgroundPanel === panel else { return }
            backgroundPanel = nil
            guard response == .OK, let url = panel.url, beautifierVisible, isPresented() else { return }
            let selected = style, selectedLayout = layout, padding = paddingPercent, radius = roundness
            beginBackgroundLoad {
                let worker = Task.detached(priority: .userInitiated) { () throws -> CGImage in
                    try Task.checkCancellation()
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard url.isFileURL, values.isRegularFile == true,
                          let size = values.fileSize, size <= 100_000_000 else {
                        throw CaptureError.message(L10n.text("请选择不超过 100 MB 的本地背景图片。"))
                    }
                    try Task.checkCancellation()
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2500,
                             kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                        throw CaptureError.message(L10n.text("背景图片无法读取。"))
                    }
                    try Task.checkCancellation(); return image
                }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                return (selected, selectedLayout, padding, radius, image)
            }
        }
    }
}

enum VideoGIFExporter {
    static func export(_ source: URL, to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: source)
        let duration = min(30, try await asset.load(.duration).seconds)
        guard duration > 0 else { throw CaptureError.message(L10n.text("视频没有可导出的帧。")) }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-\(UUID()).gif")
        defer { try? FileManager.default.removeItem(at: stage) }
        let generation = Task.detached(priority: .userInitiated) {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
            let count = Int(ceil(duration * 10))
            guard let destination = CGImageDestinationCreateWithURL(stage as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw CaptureError.message(L10n.text("无法创建 GIF 文件。")) }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            try await withTaskCancellationHandler {
                for index in 0..<count {
                    try Task.checkCancellation()
                    let image = try await generator.image(at: CMTime(seconds: Double(index) / 10, preferredTimescale: 600)).image
                    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
                    progress(Double(index + 1) / Double(count))
                }
                try Task.checkCancellation()
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.message(L10n.text("GIF 写入失败。")) }
            } onCancel: { generator.cancelAllCGImageGeneration() }
        }
        try await withTaskCancellationHandler { try await generation.value } onCancel: { generation.cancel() }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: output) }
    }
}

struct CompactLauncherView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var store: CaptureStore
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var scrollCapture: ScrollCapture
    @ObservedObject private var deviceRecorder: DeviceRecorder
    init(app: AppCoordinator, store: CaptureStore) {
        self.app = app; self.store = store
        recorder = app.recorder; scrollCapture = app.scrollCapture
        deviceRecorder = app.deviceRecorder
    }
    @State private var entryHovered = false
    @State private var hoveredMode: CaptureMode?
    private var unavailable: Bool { app.captureIsBusy }
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 9) {
                ViewfinderMark(size: 26)
                Text(AppIdentity.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Menu {
                    Button(L10n.text("重新截取上次区域")) { app.start(.region, repeatSelection: true) }.disabled(app.lastSelection == nil && app.lastDesktopRegion == nil)
                    Divider()
                    ForEach([3, 5, 10], id: \.self) { seconds in
                        Button(L10n.text("\(seconds) 秒后截图")) { app.start(.region, delay: seconds) }
                    }
                } label: { Image(systemName: "timer").font(.system(size: 14)).frame(width: 32, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L10n.text("定时与重复选区"))
                    .accessibilityLabel(L10n.text("定时与重复选区")).disabled(unavailable)
                Button { app.hideDashboard() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).frame(width: 32, height: 32)
                }.buttonStyle(StudioButtonStyle(radius: 7, quiet: true))
                    .help(L10n.text("隐藏面板（Esc），可从菜单栏重新打开")).accessibilityLabel(L10n.text("隐藏面板"))
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 3)
            VStack(spacing: 9) {
                Button { app.start(.region) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "viewfinder").font(.system(size: 32, weight: .light))
                            .frame(width: 32, height: 32).padding(10)
                            .background(Palette.onAccent.opacity(entryHovered && !unavailable ? 0.14 : 0.08),
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("区域截图")).font(.system(size: 16, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(app.shortcutLabel).font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Palette.onAccent.opacity(0.85))
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 18).frame(minHeight: 94)
                }.buttonStyle(StudioButtonStyle(primary: true, radius: 16)).accessibilityLabel(L10n.text("区域截图")).disabled(unavailable)
                    .onHover { entryHovered = $0 }
                HStack(spacing: 9) { smallCapture(.window); screenCaptureChoice }
            }
            VStack(spacing: 0) {
                ForEach([CaptureMode.scrolling, .scrollingWindow, .text, .recording]) { mode in
                    if mode == .recording { recordingChoice }
                    else if mode == .scrolling { scrollingChoice }
                    else {
                        Button { app.start(mode) } label: {
                            HStack(spacing: 11) {
                                if mode == .scrollingWindow {
                                    toolGlyph(.windowScrolling, mode: mode, tint: Palette.ice)
                                } else { toolGlyph(mode == .text ? .text : .scrolling, mode: mode, tint: tint(for: mode)) }
                                Text(mode.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
                            }.padding(.horizontal, 10).frame(height: 53)
                        }.buttonStyle(StudioButtonStyle(radius: 10, quiet: true, accentHover: true)).accessibilityLabel(mode.title).disabled(unavailable)
                            .onHover { hoveredMode = $0 ? mode : nil }
                    }
                }
            }.padding(3)
            Button { app.showBeautifier() } label: {
                HStack(spacing: 11) {
                    Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(Palette.ice).frame(width: 32, height: 32)
                    Text(L10n.text("图片美化")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
                }.padding(.horizontal, 10).frame(height: 44)
            }.buttonStyle(StudioButtonStyle(radius: 10, quiet: true, accentHover: true)).accessibilityLabel(L10n.text("图片美化"))
            HStack(spacing: 4) {
                Button { app.showHistory() } label: { Label(L10n.text("历史"), systemImage: "clock.arrow.circlepath").padding(.horizontal, 8).frame(height: 32) }
                Button { app.showSettings() } label: { Label(L10n.text("设置"), systemImage: "slider.horizontal.3").padding(.horizontal, 8).frame(height: 32) }
                Button { ShotloomSupportWindow.shared.show() } label: {
                    Image(systemName: "bubble.left.and.bubble.right").frame(width: 32, height: 32)
                }.help(L10n.translate("Support and Feedback")).accessibilityLabel(L10n.translate("Support and Feedback"))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 32, height: 32) }.help(L10n.text("退出")).accessibilityLabel(L10n.text("退出"))
            }.buttonStyle(StudioButtonStyle(radius: 7, quiet: true)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                .padding(.top, 10)
                .overlay(alignment: .top) { Rectangle().fill(Palette.separator.opacity(0.5)).frame(height: 0.5).allowsHitTesting(false) }
            if let notice = app.notice { NoticeView(text: notice, dismiss: { app.notice = nil }).fixedSize(horizontal: false, vertical: true) }
        }.padding(16).frame(width: 328).background(OpticalPanel()).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .foregroundStyle(Palette.white)
            .onChange(of: app.notice) { _, _ in app.resizeLauncher() }
    }
    private var screenCaptureChoice: some View {
        HStack(spacing: 0) {
            Button { app.start(.fullscreen) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "display").font(.system(size: 13)).foregroundStyle(Palette.ice)
                    Text(L10n.text("当前屏幕")).font(.system(size: 11, weight: .medium))
                }.frame(maxWidth: .infinity).frame(height: 40).contentShape(Rectangle())
            }.buttonStyle(StudioButtonStyle(radius: 10, quiet: true)).help(CaptureMode.fullscreen.detail).accessibilityLabel(L10n.text("当前屏幕截图"))
            if app.hasMultipleScreens {
                Divider().frame(height: 15)
                Menu {
                    Button { app.start(.allScreens) } label: { Label(L10n.text("所有屏幕截图"), systemImage: "display.2") }
                } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 26, height: 40) }
                    .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 4)
                    .help(L10n.text("所有屏幕截图：按显示器排列合成一张图片")).accessibilityLabel(L10n.text("更多屏幕截图方式"))
            }
        }.frame(maxWidth: .infinity).background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.chrome.opacity(0.07))).disabled(unavailable)
    }
    private var recordingChoice: some View {
        HStack(spacing: 0) {
            Button { app.start(.recording) } label: {
                HStack(spacing: 10) {
                    toolGlyph(.recording, mode: .recording, tint: OpticalPalette.coral)
                    Text(L10n.text("区域录屏")).font(.system(size: 13, weight: .medium))
                    Spacer()
                }.padding(.leading, 10).frame(height: 53).contentShape(Rectangle())
            }.buttonStyle(StudioButtonStyle(radius: 10, quiet: true, accentHover: true)).accessibilityLabel(L10n.text("区域录屏")).onHover { hoveredMode = $0 ? .recording : nil }
            Divider().frame(height: 15).padding(.horizontal, 6)
            Menu {
                Button(L10n.text("窗口录屏…")) { app.start(.window, recordWindow: true) }
                Button(L10n.text("iPhone / iPad 与设备录制…")) { app.showDevices() }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(OpticalPalette.coral).frame(width: 34, height: 36) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 8).help(L10n.text("窗口录屏与设备录制")).accessibilityLabel(L10n.text("更多录制方式"))
        }.disabled(unavailable)
    }
    private var scrollingChoice: some View {
        Button { app.start(.scrolling) } label: {
            HStack(spacing: 11) {
                toolGlyph(.scrolling, mode: .scrolling, tint: Palette.ice)
                Text(L10n.text("区域滚动长图")).font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 10).frame(height: 53).contentShape(Rectangle())
        }.buttonStyle(StudioButtonStyle(radius: 10, quiet: true, accentHover: true)).accessibilityLabel(L10n.text("区域滚动长图"))
            .help(L10n.text("选择区域后可设置上下左右滚动方向")).disabled(unavailable)
            .onHover { hoveredMode = $0 ? .scrolling : nil }
    }
    private func toolGlyph(_ kind: CaptureGlyph.Kind, mode: CaptureMode, tint: Color) -> some View {
        CaptureGlyph(kind: kind, tint: tint, size: 26, active: hoveredMode == mode && !unavailable)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.13)))
    }
    private func tint(for mode: CaptureMode) -> Color {
        switch mode { case .recording: OpticalPalette.coral; default: Palette.ice }
    }
    private func smallCapture(_ mode: CaptureMode) -> some View {
        Button { app.start(mode) } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.symbol).font(.system(size: 14)).foregroundStyle(Palette.ice)
                Text(L10n.text("窗口截图")).font(.system(size: 11, weight: .medium))
            }.frame(maxWidth: .infinity).frame(height: 40).contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(StudioButtonStyle(radius: 10)).accessibilityLabel(mode.title).disabled(unavailable)
    }
}


struct RecordingHUD: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var drawing: RecordingDrawingController
    let stop: () -> Void
    var resize: (CGSize) -> Void = { _ in }
    init(recorder: ScreenRecorder, stop: @escaping () -> Void, resize: @escaping (CGSize) -> Void = { _ in }) {
        self.recorder = recorder; self.drawing = recorder.drawing; self.stop = stop; self.resize = resize
    }
    static func contentSize(cameraEnabled: Bool, toolsVisible: Bool) -> CGSize {
        CGSize(width: 346, height: 44 + (toolsVisible ? 88 : 0) + (cameraEnabled ? 123 : 0))
    }
    private var height: CGFloat { Self.contentSize(cameraEnabled: recorder.cameraEnabled, toolsVisible: drawing.toolsVisible).height }
    var body: some View {
        VStack(spacing: 0) {
            if recorder.cameraEnabled { CameraLivePreview(camera: recorder.camera).frame(width: 180, height: 115).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.bottom, 8) }
            HStack(spacing: 14) {
                CaptureDragHandle().frame(width: 12, height: 24)
                Circle().fill(recorder.state == .paused ? .orange : OpticalPalette.coral).frame(width: 7, height: 7)
                Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).font(.system(size: 13, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
                Button { Task { await recorder.togglePause() } } label: { Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill") }.help(recorder.state == .paused ? L10n.text("继续录制") : L10n.text("暂停"))
                    .disabled(recorder.state != .recording && recorder.state != .paused)
                Button {
                    if drawing.toolsVisible { drawing.stopDrawing(); drawing.toolsVisible = false }
                    else { drawing.draw(drawing.selectedTool) }
                } label: { Image(systemName: "pencil.tip").foregroundStyle(drawing.toolsVisible ? Palette.ice : Palette.white) }.help(L10n.text("展开现场标注")).disabled(recorder.state != .recording)
                Button(action: stop) { Image(systemName: "stop.fill").foregroundStyle(OpticalPalette.coral) }.help(L10n.text("结束并保存"))
                SpeakerNotesControls(controller: recorder.speakerNotes)
                    .disabled(recorder.state != .recording && recorder.state != .paused)
                if recorder.state == .finishing || recorder.state == .preparing { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 16).frame(height: 44)
            if drawing.toolsVisible {
                VStack(spacing: 8) {
                    HStack(spacing: 5) {
                        ForEach([AnnotationTool.arrow, .rectangle, .ellipse, .pen, .step]) { tool in
                            Button { drawing.draw(tool) } label: {
                                Image(systemName: tool.symbol).font(.system(size: 14)).frame(width: 29, height: 26)
                                    .foregroundStyle(drawing.isDrawing && drawing.selectedTool == tool ? Palette.ice : Palette.white)
                                    .background(drawing.isDrawing && drawing.selectedTool == tool ? Palette.ice.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.help(tool.title)
                        }
                        Spacer(minLength: 0)
                        Button { drawing.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help(L10n.text("撤销"))
                        Button { drawing.clear() } label: { Image(systemName: "trash") }.help(L10n.text("清除标注"))
                    }
                    HStack(spacing: 8) {
                        ForEach([AnnotationColor.coral, .yellow, .cyan, .white]) { color in
                            Button { drawing.setColor(color) } label: {
                                Circle().fill(Color(nsColor: color.color)).frame(width: 15, height: 15)
                                    .padding(2).overlay(Circle().strokeBorder(drawing.selectedColor == color ? Palette.ice : .clear, lineWidth: 1))
                            }.help(color.title)
                        }
                        Menu {
                            ForEach([CGFloat(3), 5, 9], id: \.self) { width in Button("\(Int(width)) pt") { drawing.setWidth(width) } }
                        } label: { Text("\(Int(drawing.lineWidth)) pt").font(.system(size: 10)) }.menuStyle(.borderlessButton).fixedSize()
                        Spacer(minLength: 0)
                        Button(drawing.isDrawing ? L10n.text("继续操作") : L10n.text("继续标注")) {
                            if drawing.isDrawing { drawing.stopDrawing() } else { drawing.draw(drawing.selectedTool) }
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ice)
                    }
                    Text(drawing.isDrawing ? L10n.text("正在标注 · Esc 返回操作屏幕") : L10n.text("标注层已穿透，可操作原应用")) .font(.system(size: 9)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 12).padding(.bottom, 10).frame(height: 88).disabled(recorder.state != .recording)
            }
        }.buttonStyle(.plain).frame(width: 346, height: height).foregroundStyle(Palette.white).background(OpticalPanel(radius: 18))
            .onAppear { resize(CGSize(width: 346, height: height)) }
            .onChange(of: drawing.toolsVisible) { _, _ in resize(CGSize(width: 346, height: height)) }
            .onChange(of: recorder.cameraEnabled) { _, _ in resize(CGSize(width: 346, height: height)) }
    }
}

@MainActor
enum ScrollFileDialog {
    static var diagnosticTrace: ((String) -> Void)?
    static func complete(for scroll: ScrollCapture, copy: () -> Void) {
        if scroll.requiresStreamingExport { presentSegments(for: scroll) }
        else { copy() }
    }
    static func presentSegments(for scroll: ScrollCapture) { present(for: scroll, segments: true) }
    static func present(for scroll: ScrollCapture) { present(for: scroll, segments: false) }
    private static func present(for scroll: ScrollCapture, segments: Bool) {
        guard scroll.beginFileSelection() else { return }
        let previousApplication = NSWorkspace.shared.frontmostApplication
        let streaming = scroll.requiresStreamingExport
        let trace = segments ? "segments" : "file"
        diagnosticTrace?("\(trace)-panel-prepare-start")
        // Let the button's tracking/activation work finish and paint the paused
        // state before constructing AppKit's cold file browser on the main actor.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard scroll.active, scroll.choosingFile else { return }
            diagnosticTrace?("\(trace)-panel-activation-start")
            if !NSApp.isActive { _ = NSRunningApplication.current.activate(options: []) }
            diagnosticTrace?("\(trace)-panel-activation-end")
            try? await Task.sleep(for: .milliseconds(16))
            guard scroll.active, scroll.choosingFile else { return }
            diagnosticTrace?("\(trace)-panel-create-start")
            let panel = NSSavePanel(); panel.canCreateDirectories = true
            diagnosticTrace?("\(trace)-panel-create-end")
            if segments {
                panel.nameFieldStringValue = L10n.text("DeskCapture 长图分块")
                panel.message = L10n.text("保存原分辨率 PNG 分块及位置清单。目标为一个完整文件夹。")
            } else {
                panel.allowedContentTypes = streaming ? [.pdf] : [.png, .pdf]
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                panel.nameFieldStringValue = L10n.text("DeskCapture 长图 \(formatter.string(from: Date())).\(streaming ? "pdf" : "png")")
                panel.message = streaming ? L10n.text("内容较长，将保存为自动分页 PDF。需要原分辨率图片可返回选择分块 PNG。") : L10n.text("可保存为 PNG 长图或自动分页的 PDF。")
            }
            if let path = AppPreferences.standard.string(forKey: "lastScrollSaveDirectory") { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
            try? await Task.sleep(for: .milliseconds(16))
            guard scroll.active, scroll.choosingFile else { return }
            panel.begin { response in
                diagnosticTrace?("\(trace)-panel-response")
                let url = response == .OK ? panel.url : nil
                if let url { AppPreferences.standard.set(url.deletingLastPathComponent().path, forKey: "lastScrollSaveDirectory") }
                if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate(options: []) }
                Task {
                    if segments { await scroll.completeSegmentSelection(url) }
                    else { await scroll.completeFileSelection(url) }
                }
            }
            diagnosticTrace?("\(trace)-panel-begin-returned")
        }
    }
}

