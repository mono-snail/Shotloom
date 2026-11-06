import AppKit
import AVFoundation
import CoreMediaIO
import SwiftUI

@MainActor
final class DeviceRecorder: ObservableObject {
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var audioDevices: [AVCaptureDevice] = []
    @Published var selectedAudioID = "device-audio"
    @Published private(set) var isRefreshing = false
    @Published var selectedID = ""
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsed = 0.0
    @Published var message: String?
    let capture = RecordingCamera()
    var onFinish: ((URL) -> Void)?
    var canStart: (() -> Bool)?
    private var directory: URL?
    private var clips: [URL] = []
    private var started: Date?
    private var duration = 0.0
    private var timer: Timer?
    private var journal: RecordingSessionJournal?
    private var sessionSegments: [RecordingSessionSegment] = []
    private var lastSpaceCheck = 0.0
    private var checkingSpace = false
    private var activeDeviceID: String?
    private var activeAudioDeviceID: String?
    private var sourceLost = false
    private var deviceObservers: [NSObjectProtocol] = []
    init() {
        capture.setStoppedHandler { [weak self] event in
            Task { @MainActor in
                guard let self, event.unexpected, self.state == .recording, event.file.deletingLastPathComponent() == self.directory, event.file.lastPathComponent == self.sessionSegments.last?.video else { return }
                self.message = event.message.map { L10n.text("视频源已停止：") + $0 + L10n.text("。正在保留素材。") } ?? L10n.text("视频源已结束输出，正在保存已完成的片段。")
                await self.stop()
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let device = notification.object as? AVCaptureDevice else { return }
                    if notification.name == AVCaptureDevice.wasDisconnectedNotification,
                       self.activeDeviceID == device.uniqueID || self.activeAudioDeviceID == device.uniqueID, self.state != .idle {
                        self.sourceLost = true; self.message = L10n.text("所选视频或音频源已断开，正在保留原片；不会自动换用其他设备。")
                        if self.state == .recording || self.state == .paused { Task { await self.stop() } }
                        else if self.state == .preparing { self.capture.shutdown() }
                    } else if self.state == .idle { Task { await self.refresh() } }
                }
            })
        }
    }
    deinit { for observer in deviceObservers { NotificationCenter.default.removeObserver(observer) } }
    func refresh() async {
        guard state == .idle, !isRefreshing else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let found = await Task.detached(priority: .userInitiated) {
            var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: 0)
            var allow: UInt32 = 1
            _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
            let video = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .continuityCamera, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
            let audio = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            return (video, audio)
        }.value
        guard state == .idle else { return }
        devices = found.0; audioDevices = found.1
        if selectedID.isEmpty { selectedID = devices.first?.uniqueID ?? "" }
        if !selectedID.isEmpty && !devices.contains(where: { $0.uniqueID == selectedID }) { message = L10n.text("原视频源当前不可用；连接后刷新，或明确选择另一个视频源。") }
        else { message = devices.isEmpty ? L10n.text("没有可用视频源。连接并信任 USB 设备后刷新。") : nil }
    }
    func start(diagnostic: Bool = false) async {
        guard state == .idle else { return }
        guard canStart?() != false else { message = L10n.text("请先完成当前截图、长图或录制。"); return }
        state = .preparing; message = nil; activeDeviceID = selectedID; sourceLost = false
        let deviceID = selectedID
        let audioDeviceID: String? = selectedAudioID == "no-audio" ? nil : (selectedAudioID == "device-audio" ? deviceID : selectedAudioID)
        activeAudioDeviceID = audioDeviceID
        do {
            guard devices.contains(where: { $0.uniqueID == selectedID }) else { throw CaptureError.message(L10n.text("所选设备已断开，请刷新设备列表。")) }
            let storage = diagnostic ? FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-diagnostics", isDirectory: true) : RecordingLibrary.directory
            let folder = storage.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
                try RecordingStorageBudget.require(storage, bytes: 512_000_000)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }.value
            journal = try await RecordingSessionJournal.create(directory: folder, fps: 30, smoothCursor: false)
            sessionSegments = []; lastSpaceCheck = 0
            directory = folder; clips = []; duration = 0; elapsed = 0
            try await capture.prepare(deviceID: deviceID, audioDeviceID: audioDeviceID)
            guard !sourceLost else { throw CaptureError.message(L10n.text("准备期间原视频源已断开，未启动另一台设备。")) }
            try await begin()
        } catch { await interruptJournal(); capture.shutdown(); state = .idle; message = error.localizedDescription }
    }
    private func begin() async throws {
        guard let directory else { throw CaptureError.message(L10n.text("设备录制目录失效。")) }
        let file = directory.appendingPathComponent("device-\(clips.count).mov")
        guard sessionSegments.count < 1000 else { throw CaptureError.message(L10n.text("录制分段已达1000段，请保存后新建。")) }
        sessionSegments.append(.init(video: file.lastPathComponent, sourceStart: duration))
        try await journal?.checkpoint(segments: sessionSegments, status: .preparing, events: [], drawing: [])
        guard !sourceLost else { throw CaptureError.message(L10n.text("原视频源已断开，请保存后重新选择。")) }
        started = try await capture.begin(file, recoveryLease: journal?.lease)
        guard !sourceLost else { throw CaptureError.message(L10n.text("原视频源在启动时断开，原片保留。")) }
        state = .recording
        try await journal?.checkpoint(segments: sessionSegments, status: .recording, events: [], drawing: [])
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; self.elapsed = self.duration + (self.started.map { Date().timeIntervalSince($0) } ?? 0); self.checkSpace() } }
    }
    private func finish() async throws {
        timer?.invalidate(); timer = nil
        let source = try await capture.end(), asset = AVURLAsset(url: source)
        defer { withExtendedLifetime(asset) {} }
        if activeAudioDeviceID != nil, try await asset.loadTracks(withMediaType: .audio).isEmpty {
            throw CaptureError.message(L10n.text("所选音频源没有写入音轨，原始视频已保留；请检查设备的音频输出或选择其他音频输入。"))
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough), let directory else { throw CaptureError.message(L10n.text("设备视频导出失败。")) }
        let output = directory.appendingPathComponent("segment-\(clips.count).mp4")
        try await VideoExport.export(exporter, to: output, as: .mp4); clips.append(output)
        let seconds = try await asset.load(.duration).seconds
        sessionSegments[sessionSegments.count - 1].duration = seconds; sessionSegments[sessionSegments.count - 1].sealed = true
        try await journal?.checkpoint(segments: sessionSegments, status: .paused, events: [], drawing: [])
        duration += seconds; elapsed = duration; started = nil
    }
    private func interruptJournal() async {
        let current = journal, segments = sessionSegments
        try? await current?.checkpoint(segments: segments, status: .interrupted, events: [], drawing: [])
        journal = nil
    }
    private func checkSpace() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !checkingSpace, now - lastSpaceCheck >= 5, state == .recording, let folder = directory else { return }
        checkingSpace = true; lastSpaceCheck = now
        Task {
            defer { checkingSpace = false }
            do { try await Task.detached(priority: .utility) { try RecordingStorageBudget.require(folder, bytes: 256_000_000) }.value }
            catch {
                guard directory == folder, state == .recording else { return }
                message = error.localizedDescription; await stop()
            }
        }
    }
    func togglePause() async {
        guard state == .recording || state == .paused else { return }
        let pause = state == .recording; state = .preparing
        do { if pause { try await finish(); state = .paused } else { try await begin() } }
        catch { await interruptJournal(); message = L10n.text("设备片段未完成：\(error.localizedDescription)。原始素材保留。"); timer?.invalidate(); capture.shutdown(); state = .idle }
    }
    func stop() async {
        guard state == .recording || state == .paused else { return }
        let paused = state == .paused; state = .finishing
        do {
            if !paused { try await finish() }
            guard let directory, !clips.isEmpty else { throw CaptureError.message(L10n.text("设备录制没有完成的分段。")) }
            let output = directory.appendingPathComponent("DeskCapture-设备-\(Int(Date().timeIntervalSince1970)).mp4")
            let snapshotClips = clips
            try await Task.detached(priority: .utility) {
                let bytes = try snapshotClips.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                try RecordingStorageBudget.require(directory, bytes: bytes + 256_000_000)
            }.value
            try await ScreenRecorder.join(clips, to: output)
            try await journal?.checkpoint(segments: sessionSegments, status: .completed, events: [], drawing: [], finalFile: output.lastPathComponent)
            journal = nil
            capture.shutdown(); state = .idle; onFinish?(output)
        } catch { await interruptJournal(); timer?.invalidate(); capture.shutdown(); state = .idle; message = L10n.text("保存未完成：\(error.localizedDescription)。原始素材保留在录屏目录。") }
    }
}

struct DeviceRecordingView: View {
    @ObservedObject var recorder: DeviceRecorder
    var close: () -> Void = {}
    var refreshOnAppear = true
    var body: some View {
        StudioWorkspace(title: L10n.text("设备录制"), symbol: "video") {
            Button(recorder.isRefreshing ? L10n.text("刷新中…") : L10n.text("刷新设备")) { Task { await recorder.refresh() } }
                .disabled(recorder.state != .idle || recorder.isRefreshing)
        } preview: {
            if recorder.state != .idle {
                CameraLivePreview(camera: recorder.capture).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "video").font(.system(size: 40, weight: .light)).foregroundStyle(Palette.muted)
                    Text(recorder.devices.isEmpty ? L10n.text("未找到视频源") : L10n.text("选择视频源后开始录制"))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } inspector: {
            InspectorGroup(L10n.text("视频源"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("设备")) {
                    Picker(L10n.text("视频源"), selection: $recorder.selectedID) {
                        if recorder.devices.isEmpty && recorder.selectedID.isEmpty { Text(L10n.text("暂无设备")).tag("") }
                        if !recorder.selectedID.isEmpty && !recorder.devices.contains(where: { $0.uniqueID == recorder.selectedID }) { Text(L10n.text("原视频源不可用")).tag(recorder.selectedID) }
                        ForEach(recorder.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }.disabled(recorder.state != .idle || recorder.isRefreshing)
                InspectorField(title: L10n.text("声音来源")) {
                    Picker(L10n.text("声音来源"), selection: $recorder.selectedAudioID) {
                        Text(L10n.text("所选设备的声音")).tag("device-audio")
                        Text(L10n.text("不录声音")).tag("no-audio")
                        if !["device-audio", "no-audio"].contains(recorder.selectedAudioID),
                           !recorder.audioDevices.contains(where: { $0.uniqueID == recorder.selectedAudioID }) {
                            Text(L10n.text("原音频源不可用")).tag(recorder.selectedAudioID)
                        }
                        ForEach(recorder.audioDevices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }.disabled(recorder.state != .idle || recorder.isRefreshing)
            }
            if let message = recorder.message { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            Text(String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60)).monospacedDigit()
            if recorder.state == .preparing || recorder.state == .finishing {
                ProgressView().controlSize(.small)
                Text(recorder.state == .finishing ? L10n.text("正在结束录制并保存…") : L10n.text("正在准备录制…"))
            }
            Spacer()
            Button(recorder.state == .idle ? L10n.text("关闭") : L10n.text("完成并关闭"), action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(recorder.state == .preparing || recorder.state == .finishing)
            if recorder.state == .idle {
                Button(L10n.text("开始录制")) { Task { await recorder.start() } }
                    .disabled(recorder.selectedID.isEmpty || recorder.isRefreshing || !recorder.devices.contains(where: { $0.uniqueID == recorder.selectedID }))
                    .buttonStyle(StudioButtonStyle(primary: true, command: true))
            } else {
                Button(recorder.state == .paused ? L10n.text("继续") : L10n.text("暂停")) { Task { await recorder.togglePause() } }
                    .disabled(recorder.state != .paused && recorder.state != .recording)
                Button(L10n.text("完成并保存")) { Task { await recorder.stop() } }
                    .disabled(recorder.state != .paused && recorder.state != .recording).buttonStyle(StudioButtonStyle(primary: true, command: true))
            }
        }.task { if refreshOnAppear { await recorder.refresh() } }
    }
}

@MainActor
final class DeviceRecordingWindow: NSWindow, NSWindowDelegate {
    private let recorder: DeviceRecorder
    init(recorder: DeviceRecorder) {
        self.recorder = recorder
        super.init(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = L10n.text("设备录制"); isReleasedWhenClosed = false; delegate = self
        contentMinSize = StudioMetrics.workspaceMinimum
        contentView = NSHostingView(rootView: DeviceRecordingView(recorder: recorder, close: { [weak self] in self?.performClose(nil) }))
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if recorder.state == .idle { return true }
        guard recorder.state == .recording || recorder.state == .paused else { return false }
        Task {
            await recorder.stop()
            // Keep a failed save visible so the user can read the error.
            if recorder.state == .idle, recorder.message == nil { close() }
        }
        return false
    }
}
