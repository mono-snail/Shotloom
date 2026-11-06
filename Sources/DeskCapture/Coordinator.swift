import AppKit
import SwiftUI
import Combine

private final class CaptureToastPanel: NSPanel {}
private final class ProjectImportPanel: NSPanel {
    var cancelImport: (() -> Void)?
    override func close() { cancelImport?(); super.close() }
}
import ScreenCaptureKit
import UniformTypeIdentifiers
import PDFKit

@MainActor
final class AppCoordinator: ObservableObject {
    let store: CaptureStore
    let updates = AppUpdateController()
    var hasClipboardSaves: Bool { clipboardEditors.contains { $0.isSaving } }
    var updateBlockReason: String? {
        func open(_ window: NSWindow) -> Bool { window.isVisible || window.isMiniaturized || hiddenWindows.contains { $0 === window } }
        return AppUpdateActivity(
            recording: recorder.state != .idle || deviceRecorder.state != .idle,
            capturing: isCapturing || scrollCapture.active || scrollCapture.finishing,
            processing: hasClipboardSaves || hasImageHistorySaves || hasImageFileExports || isRecognizing || historyImageTask != nil || cleanupPreparationTask != nil || imageCopyTask != nil || projectImportTask != nil,
            editing: editors.contains(where: open) || videoWindows.contains(where: open) || clipboardEditors.contains { open($0.window) }
                || pins.contains(where: open)
        ).blockReason
    }
    private let imagePasteboard: NSPasteboard
    // Optional diagnostic observers; default app behavior is unchanged.
    var onSelectionPresented: (() -> Void)?
    var onImageCopyCompleted: (() -> Void)?
    let hotKey = GlobalHotKey()
    let recorder = ScreenRecorder()
    let scrollCapture = ScrollCapture()
    /// The launcher, menus and dispatch must agree before offering a new capture.
    var captureIsBusy: Bool {
        isCapturing || recorder.state != .idle || deviceRecorder.state != .idle
            || scrollCapture.active || scrollCapture.finishing
    }
    private let scrollRegionOutline = ScrollRegionOutline()
    private var lastScrollSelection: LastCaptureSelection?
    var scrollOutlineVisibleForDiagnostics: Bool { scrollRegionOutline.isVisible }
    var scrollSelectionForDiagnostics: CGRect?
    let deviceRecorder = DeviceRecorder()
    private var deviceWindow: NSWindow?
    private let engine = CaptureEngine()
    @Published var isCapturing = false
    @Published var permission = CaptureEngine.hasPermission
    // Installed only for the interactive app; isolated diagnostics retain their own entry points.
    var requirePermission: (() -> Bool)?
    var permissionWasDenied: (() -> Void)?
    @Published var notice: String?
    @Published var shortcut = HotKeyPreset(rawValue: AppPreferences.standard.integer(forKey: "hotKeyPreset")) ?? .commandShift2
    @Published var customBinding: HotKeyBinding? = AppPreferences.standard.data(forKey: "customHotKey").flatMap { try? JSONDecoder().decode(HotKeyBinding.self, from: $0) }
    @Published var modeBindings: [String: HotKeyBinding] = AppPreferences.standard.data(forKey: "modeHotKeys")
        .flatMap { try? JSONDecoder().decode([String: HotKeyBinding].self, from: $0) } ?? [:]
    private var modeHotKeys: [String: GlobalHotKey] = [:]
    @Published var primaryShortcutEnabled = AppPreferences.standard.object(forKey: "primaryShortcutEnabled") as? Bool ?? true
    var shortcutLabel: String { primaryShortcutEnabled ? (customBinding?.label ?? shortcut.label) : L10n.text("未设置") }
    @Published var selectedID: UUID?
    @Published var isRecognizing = false
    @Published var recognitionErrors: [UUID: String] = [:]
    private var recognitionIDs: Set<UUID> = []
    private var pendingTextCopies: [UUID: (token: UUID, changeCount: Int)] = [:]
    private var textDeliveryToken = UUID()
    var textRecognizerForDiagnostics: ((CGImage) async throws -> String)?
    private var historyImageTask: Task<Void, Never>?
    private var historyImageToken = UUID()
    private let historyImageReader: @Sendable (URL) throws -> CGImage
    private let historyImageLoader = HistoryImageLoader()
    @Published private(set) var imageHistorySaves: Set<ObjectIdentifier> = []
    var hasImageHistorySaves: Bool { !imageHistorySaves.isEmpty }
    func isSavingImageHistory(_ document: AnnotationDocument) -> Bool { imageHistorySaves.contains(ObjectIdentifier(document)) }
    @Published private(set) var imageExportStatus: [ObjectIdentifier: String] = [:]
    private var imageFileExports: [ObjectIdentifier: ImageFileExportOperation] = [:]
    var hasImageFileExports: Bool { !imageFileExports.isEmpty }
    func imageExportStatus(in window: NSWindow) -> String? { imageExportStatus[ObjectIdentifier(window)] }
    func cancelImageExport(in window: NSWindow) { imageFileExports[ObjectIdentifier(window)]?.cancel() }
    private var imageCopyTask: Task<ImageDeliveryOutcome, Never>?
    private var imageCopyToken = UUID()
    private var cleanupPreparationTask: Task<Void, Never>?
    private var cleanupPreparationToken = UUID()
    var dashboard: NSWindow?
    private var session: SelectionSession?
    private var editors: [NSWindow] = []
    private var clipboardEditors: [ClipboardEditor] = []
    private var pins: [NSWindow] = []
    private var previousApplication: NSRunningApplication?
    private var previousKeyWindow: NSWindow?
    private var toast: NSPanel?
    private var hiddenWindows: [NSWindow] = []
    private var noticeTask: Task<Void, Never>?
    private var screenSubscription: AnyCancellable?
    private var captureStateSubscription: AnyCancellable?
    @Published private(set) var screenCount = NSScreen.screens.count
    var hasMultipleScreens: Bool { CaptureMode.allScreens.isAvailable(screenCount: screenCount) }
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var activityHUD: NSPanel?
    private var videoWindow: NSWindow?
    private var videoWindows: [NSWindow] = []
    private var projectImportTask: Task<Void, Never>?
    private var projectImportPanel: ProjectImportPanel?
    private var workflowWindow: NSWindow?
    private var recordingLibraryWindow: NSWindow?
    private var pendingCapture: Task<Void, Never>?
    private var captureGeneration = UUID()
    private var workflowInputID: UUID?
    private var workflowInputCompletion: ((Result<CGImage, Error>) -> Void)?
    var workflowInputRectForDiagnostics: CGRect?
    @Published var lastDesktopRegion: DesktopRegionMemory? = AppPreferences.standard.data(forKey: "lastDesktopRegion").flatMap { try? JSONDecoder().decode(DesktopRegionMemory.self, from: $0) }
    @Published var lastSelection: LastCaptureSelection? = AppPreferences.standard.data(forKey: "lastSelection").flatMap { try? JSONDecoder().decode(LastCaptureSelection.self, from: $0) }
    @Published var automaticScrolling = ScrollAutomationAvailability.enabled && (AppPreferences.standard.object(forKey: "automaticScrolling") as? Bool ?? true)

    init(store: CaptureStore = CaptureStore(pruneOnInit: false, deferLoading: true), imagePasteboard: NSPasteboard = .general, registerHotKeys: Bool = true,
         historyImageReader: @escaping @Sendable (URL) throws -> CGImage = { try CaptureImageRead.load($0, maximumFileBytes: 400_000_000, decodeImmediately: true) }) {
        self.store = store; self.imagePasteboard = imagePasteboard; self.historyImageReader = historyImageReader
        Task {
            do { try await store.loadInitial(); try await store.pruneExpiredAsync() }
            catch { /* CaptureStore publishes the current failure without discarding files. */ }
        }
        screenSubscription = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshScreenAvailability() }

        // Forward lifecycle changes, not elapsed time or every preview frame.
        // Views observing the coordinator can then use captureIsBusy reliably.
        captureStateSubscription = Publishers.MergeMany([
            recorder.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            deviceRecorder.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            scrollCapture.$active.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            scrollCapture.$finishing.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]).receive(on: RunLoop.main).sink { [weak self] in self?.objectWillChange.send() }

        deviceRecorder.canStart = { [weak self] in
            guard let self else { return false }; return !self.captureIsBusy
        }
        deviceRecorder.onFinish = { [weak self] url in self?.showVideo(url) }
        hotKey.onPress = { [weak self] in
            Task { @MainActor in
                guard let self, !(NSApp.keyWindow?.firstResponder is ShortcutCaptureField) else { return }
                if self.deviceRecorder.state == .recording || self.deviceRecorder.state == .paused { await self.deviceRecorder.stop() }
                else if self.recorder.state == .recording || self.recorder.state == .paused { await self.recorder.stop() }
                else if self.scrollCapture.active { await self.scrollCapture.finish() }
                else if self.isCapturing && self.session == nil { self.pendingCapture?.cancel(); self.endCapture() }
                else { self.start(.region) }
            }
        }
        if registerHotKeys {
            if primaryShortcutEnabled && !hotKey.register(customBinding ?? HotKeyBinding(shortcut)) { notice = L10n.text("热键被其他应用占用，请在设置中选择另一个组合。") }
            let savedBindings = modeBindings
            modeBindings = [:]
            for (key, binding) in savedBindings {
                if let mode = CaptureMode(rawValue: key), mode != .region { setModeShortcut(mode, binding: binding, notify: false) }
            }
        }
        recorder.onFinish = { [weak self] url in self?.activityHUD?.close(); LocalUsage.shared.record("capture.recording"); self?.showVideo(url, cameraWasRequested: self?.recorder.recordedWithCamera == true) }
        recorder.onError = { [weak self] error in
            guard let self else { return }
            self.activityHUD?.close()
            if case CaptureError.permission = CaptureEngine.normalizedCaptureError(error), let denied = self.permissionWasDenied {
                self.permission = false; denied()
            } else { self.flash(error.localizedDescription); self.showDashboard() }
        }
        scrollCapture.onAutomationPermissionPresentation = { [weak self] presenting in
            guard let panel = self?.activityHUD else { return }
            panel.level = presenting ? .normal : .floating
            if presenting { panel.orderBack(nil) }
            else { panel.orderFrontRegardless() }
        }
        scrollCapture.onPrepareClipboard = { [weak self] image in
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            let job = self.copy(backingScale: self.scrollCapture.backingScale, loadImage: { image })
            let outcome = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
            switch outcome {
            case .copied: return // Clipboard commit is the handoff boundary.
            case .cancelled: throw CancellationError()
            case .failed(let message): throw CaptureError.message(message)
            case .saved: throw CaptureError.message(L10n.text("复制未完成，长图仍保留。"))
            }
        }
        scrollCapture.onPrepareEditor = { [weak self] image in
            guard let self else { throw CancellationError() }
            let mode = self.scrollCapture.source.captureMode, scale = self.scrollCapture.backingScale
            let record = try await self.store.addAsync(image, mode: mode, backingScale: scale)
            self.selectedID = record.id
            if AppPreferences.standard.object(forKey: "autoOCRIndex") as? Bool != false { self.recognize(record) }
            self.openEditor(record)
        }
        scrollCapture.onFinish = { [weak self] image, output in
            self?.activityHUD?.close()
            self?.scrollRegionOutline.close()
            switch output {
            case .clipboard: self?.finish(image, mode: self?.scrollCapture.source.captureMode ?? .scrolling, backingScale: self?.scrollCapture.backingScale, clipboardAlreadyDelivered: true)
            case .file(let url): self?.finish(image, mode: self?.scrollCapture.source.captureMode ?? .scrolling, destination: .file, savedFile: url, backingScale: self?.scrollCapture.backingScale)
            case .editor: self?.endCapture(restoreFocus: false)
            case .segments: break
            }
        }
        scrollCapture.onStreamExport = { [weak self] url in
            self?.activityHUD?.close(); self?.scrollRegionOutline.close(); self?.flash(L10n.text("长图已完整导出"))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func refreshScreenAvailability() {
        screenCount = NSScreen.screens.count
    }

    func setModeShortcut(_ mode: CaptureMode, binding: HotKeyBinding?, notify: Bool = true) {
        guard mode != .region else { return }
        if let binding {
            let primary = customBinding ?? HotKeyBinding(shortcut)
            guard !(primaryShortcutEnabled && primary.keyCode == binding.keyCode && primary.modifiers == binding.modifiers),
                  !modeBindings.contains(where: { $0.key != mode.rawValue && $0.value.keyCode == binding.keyCode && $0.value.modifiers == binding.modifiers }) else {
                if notify { flash(L10n.text("这个组合已用于其他捕获模式。")) }; return
            }
            let key = modeHotKeys[mode.rawValue] ?? GlobalHotKey()
            guard key.register(binding) else { if notify { flash(L10n.text("热键被其他应用占用，原组合仍可用。")) }; return }
            key.onPress = { [weak self] in
                Task { @MainActor in
                    guard let self, !(NSApp.keyWindow?.firstResponder is ShortcutCaptureField) else { return }
                    if mode == .recording && (self.recorder.state == .recording || self.recorder.state == .paused) { await self.recorder.stop() }
                    else if (mode == .scrolling || mode == .scrollingWindow) && self.scrollCapture.active { await self.scrollCapture.finish() }
                    else { self.start(mode) }
                }
            }
            modeHotKeys[mode.rawValue] = key; modeBindings[mode.rawValue] = binding
        } else {
            modeHotKeys.removeValue(forKey: mode.rawValue)?.unregister(); modeBindings.removeValue(forKey: mode.rawValue)
        }
        if let data = try? JSONEncoder().encode(modeBindings) { AppPreferences.standard.set(data, forKey: "modeHotKeys") }
        if notify { flash(binding == nil ? L10n.text("该模式热键已清除。") : L10n.text("\(mode.title)热键已保存。")) }
    }
    private func conflictsWithModeKeys(_ binding: HotKeyBinding) -> Bool {
        modeBindings.values.contains { $0.keyCode == binding.keyCode && $0.modifiers == binding.modifiers }
    }
    func setShortcut(_ preset: HotKeyPreset) {
        guard preset != shortcut || customBinding != nil || !primaryShortcutEnabled else { return }
        if !conflictsWithModeKeys(HotKeyBinding(preset)), hotKey.register(preset) {
            primaryShortcutEnabled = true; AppPreferences.standard.set(true, forKey: "primaryShortcutEnabled")
            shortcut = preset; AppPreferences.standard.set(preset.rawValue, forKey: "hotKeyPreset")
            customBinding = nil; AppPreferences.standard.removeObject(forKey: "customHotKey")
            flash(L10n.text("热键已设为 \(preset.label)"))
        } else { flash(L10n.text("这个热键已被占用，原来的热键仍然可用。")) }
    }
    func setCustomShortcut(_ binding: HotKeyBinding) {
        guard !conflictsWithModeKeys(binding), hotKey.register(binding) else { flash(L10n.text("组合键已被占用，原来的热键仍可用。")); return }
        primaryShortcutEnabled = true; AppPreferences.standard.set(true, forKey: "primaryShortcutEnabled")
        customBinding = binding
        if let data = try? JSONEncoder().encode(binding) { AppPreferences.standard.set(data, forKey: "customHotKey") }
        flash(L10n.text("热键已设为 \(binding.label)"))
    }

    func clearPrimaryShortcut() {
        hotKey.unregister()
        primaryShortcutEnabled = false
        customBinding = nil
        AppPreferences.standard.set(false, forKey: "primaryShortcutEnabled")
        AppPreferences.standard.removeObject(forKey: "customHotKey")
        flash(L10n.text("区域截图热键已清除。"))
    }

    func showDashboard() {
        guard requirePermission?() != false else { return }
        if dashboard == nil {
            let window = LauncherPanel(contentRect: CGRect(x: 0, y: 0, width: 328, height: 422),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.title = "\(AppIdentity.name)"
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: DashboardView(app: self, store: store))
            if let screen = NSScreen.main { window.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - 344, y: screen.visibleFrame.maxY - 438)) }
            dashboard = window
        }
        refreshScreenAvailability()
        resizeLauncher()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let panel = dashboard as? LauncherPanel, let screen {
            panel.restorePresentation(in: screen.visibleFrame)
        }
    }

    func hideDashboard() { dashboard?.orderOut(nil) }

    func showDevices() {
        guard requirePermission?() != false else { return }
        if deviceWindow == nil {
            let window = DeviceRecordingWindow(recorder: deviceRecorder)
            window.center(); deviceWindow = window
        }
        dashboard?.orderOut(nil); NSApp.activate(ignoringOtherApps: true); deviceWindow?.makeKeyAndOrderFront(nil)
    }
    func showHistory() {
        guard requirePermission?() != false else { return }
        if historyWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 650), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L10n.text("捕获历史"); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear; window.isReleasedWhenClosed = false
            window.contentMinSize = StudioMetrics.libraryMinimum
            window.contentView = NSHostingView(rootView: HistoryView(app: self, store: store)); window.center(); historyWindow = window
        }
        dashboard?.orderOut(nil); NSApp.activate(ignoringOtherApps: true); historyWindow?.makeKeyAndOrderFront(nil)
    }
    func showRecordings() {
        guard requirePermission?() != false else { return }
        if recordingLibraryWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 460), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L10n.text("录屏素材"); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
            window.contentMinSize = StudioMetrics.libraryMinimum
            window.contentView = NSHostingView(rootView: RecordingLibraryView(app: self)); window.center(); recordingLibraryWindow = window
        }
        dashboard?.orderOut(nil); NSApp.activate(ignoringOtherApps: true); recordingLibraryWindow?.makeKeyAndOrderFront(nil)
    }
    func showSettings() {
        guard requirePermission?() != false else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 840, height: 680), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentMinSize = StudioMetrics.settingsMinimum
            window.title = L10n.text("\(AppIdentity.name) 设置"); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.isOpaque = false; window.backgroundColor = .clear; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(app: self, close: { [weak window] in window?.close() })); window.center(); settingsWindow = window
        }
        dashboard?.orderOut(nil); NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openPermissionSettings() {
        if !permission, let permissionWasDenied { permissionWasDenied(); return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @discardableResult func pickWorkflowInput(_ mode: CaptureMode, completion: @escaping (Result<CGImage, Error>) -> Void) throws -> UUID {
        guard mode == .region || mode == .window, !captureIsBusy, session == nil,
              NSApp.modalWindow == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { throw CaptureError.message(L10n.text("请先结束当前捕获、录制或对话框，再选取工作流输入。")) }
        let id = UUID(); workflowInputID = id; workflowInputCompletion = completion
        start(mode, inputOnly: true)
        guard isCapturing else { workflowInputID = nil; workflowInputCompletion = nil; throw CaptureError.message(L10n.text("输入选择未能启动，原图保持。")) }
        return id
    }
    func cancelWorkflowInput(_ id: UUID) { if workflowInputID == id { cancelCapture() } }
    @discardableResult func confirmWorkflowInputForDiagnostics() -> Bool { guard workflowInputID != nil else { return false }; return session?.confirmInputForDiagnostics() ?? false }
    func start(_ mode: CaptureMode, delay: Int = 0, repeatSelection: Bool = false, recordWindow: Bool = false, scrollDirection: ScrollDirection = .forward, inputOnly: Bool = false) {
        guard requirePermission?() != false else { return }
        if let session { session.cancel(); return }
        guard !captureIsBusy else { return }
        guard NSApp.modalWindow == nil, !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
            flash(L10n.text("请先关闭当前对话框，再开始截图。"))
            return
        }
        refreshScreenAvailability()
        guard mode.isAvailable(screenCount: screenCount) else {
            flash(L10n.text("当前只有一个屏幕，请使用当前屏幕截图。")); return
        }
        isCapturing = true
        invalidateTextDelivery()
        let currentScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let currentDisplayID = currentScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        notice = nil
        previousApplication = NSWorkspace.shared.frontmostApplication
        previousKeyWindow = NSApp.keyWindow
        hiddenWindows = NSApp.windows.filter { $0.isVisible && !($0 is CaptureToastPanel) }
        hiddenWindows.forEach { $0.orderOut(nil) }
        toast?.close(); toast = nil
        showToast(L10n.text("正在准备捕获"), symbol: "viewfinder")
        captureGeneration = UUID()
        let generation = captureGeneration
        pendingCapture = Task { [self] in
            do {
                for remaining in stride(from: max(0, min(10, delay)), to: 0, by: -1) {
                    showToast(L10n.text("\(remaining) 秒后截图 · 热键取消"), symbol: "timer")
                    try await Task.sleep(for: .seconds(1))
                }
                // ScreenCaptureKit excludes this process's windows. One display
                // interval lets AppKit submit the hide without adding a fixed
                // 160 ms to every hotkey request; capture remains fresh.
                try await Task.sleep(for: .milliseconds(16))
                let content = try await engine.content()
                try Task.checkCancellation()
                guard captureGeneration == generation else { return }
                permission = true
                if mode == .fullscreen, currentDisplayID == nil {
                    throw CaptureError.message(L10n.text("没有找到鼠标所在的显示器，请重新连接显示器后重试。"))
                }
                let snapshots = try await engine.snapshots(content: content, displayID: mode == .fullscreen ? currentDisplayID : nil)
                try Task.checkCancellation()
                guard captureGeneration == generation else { return }
                if repeatSelection && lastDesktopRegion?.compatible(snapshots) != true && !snapshots.contains(where: { lastSelection?.selection(for: $0.screen) != nil }) {
                    throw CaptureError.message(L10n.text("上次选区的显示器或缩放已改变，请重新选择区域。"))
                }
                if mode == .fullscreen {
                    let target = snapshots[0]
                    finish(target.image, mode: mode, backingScale: target.screen.backingScaleFactor)
                } else if mode == .allScreens {
                    guard mode.isAvailable(screenCount: snapshots.count) else {
                        throw CaptureError.message(L10n.text("当前可捕获的屏幕不足两个，请使用当前屏幕截图。"))
                    }
                    guard let desktop = DesktopCapture.combine(snapshots) else {
                        throw CaptureError.message(L10n.text("所有屏幕图片合成失败，请尝试当前屏幕截图。"))
                    }
                    finish(desktop.image, mode: mode, backingScale: desktop.scale)
                } else {
                    let selection = SelectionSession(snapshots: snapshots, windows: content.windows, mode: mode == .scrollingWindow ? .window : mode, previewRect: inputOnly ? workflowInputRectForDiagnostics : (mode == .scrolling ? scrollSelectionForDiagnostics : nil),
                                                     lastSelection: mode == .scrolling ? lastScrollSelection : (repeatSelection ? lastSelection : nil), recorder: recorder, recordWindow: recordWindow, lastDesktop: repeatSelection ? lastDesktopRegion : nil, inputOnly: inputOnly, colorPasteboard: imagePasteboard, scrollingWindow: mode == .scrollingWindow, initialScrollDirection: scrollDirection)
                    selection.onSelection = { [weak self] screen, rect in
                        guard !inputOnly else { return }
                        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return }
                        let frozen = snapshots.first { ($0.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == id }
                        do { try frozen?.topology?.requireUnchanged() } catch { return }
                        let geometry = frozen?.topology?.displays.first { $0.id == id }
                        let value = LastCaptureSelection(displayID: id, screenSize: frozen?.frame.size ?? screen.frame.size, rect: rect, identity: geometry?.identity, backingScale: geometry?.scale)
                        self?.lastDesktopRegion = nil; AppPreferences.standard.removeObject(forKey: "lastDesktopRegion")
                        self?.lastSelection = value
                        if let data = try? JSONEncoder().encode(value) { AppPreferences.standard.set(data, forKey: "lastSelection") }
                    }
                    selection.onDesktopSelection = { [weak self] rect in
                        guard !inputOnly else { return }
                        do { for topology in snapshots.compactMap(\.topology) { try topology.requireUnchanged() } } catch { return }
                        let saved = DesktopRegionMemory(rect: rect, screens: snapshots.map(\.screen)); self?.lastDesktopRegion = saved; self?.lastSelection = nil
                        AppPreferences.standard.removeObject(forKey: "lastSelection")
                        if let data = try? JSONEncoder().encode(saved) { AppPreferences.standard.set(data, forKey: "lastDesktopRegion") }
                    }
                    selection.onComplete = { [weak self] image, destination, document in
                        guard let self else { return }
                        if inputOnly {
                            let reply = self.workflowInputCompletion
                            self.workflowInputCompletion = nil; self.workflowInputID = nil
                            self.endCapture(); reply?(.success(image))
                        } else { self.finish(image, mode: mode, destination: destination, document: document) }
                    }
                    selection.onError = { [weak self] error in self?.fail(error) }
                    selection.onRegionAction = { [weak self] screen, rect, destination, target, orientation in
                        self?.beginRegionActivity(screen: screen, rect: rect, destination: destination, content: content,
                                                  window: target, scrollDirection: orientation.direction, scrollAxis: orientation.axis)
                    }
                    selection.onWindowRecording = { [weak self] window, screen in
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        let rect = CGRect(x: window.frame.minX - screen.frame.minX, y: top - window.frame.maxY - screen.frame.minY, width: window.frame.width, height: window.frame.height)
                        self?.beginRegionActivity(screen: screen, rect: rect, destination: .recording, content: content, window: window)
                    }
                    selection.onCancel = { [weak self] in self?.endCapture() }
                    session = selection
                    NSApp.activate(ignoringOtherApps: true)
                    selection.show()
                    if onSelectionPresented != nil {
                        selection.displayForMeasurement()
                        onSelectionPresented?()
                    }
                }
            } catch is CancellationError { }
            catch { if captureGeneration == generation, !Task.isCancelled { fail(error) } }
        }
    }

    func cancelCapture() {
        invalidateTextDelivery()
        if let session { session.cancel() }
        else { pendingCapture?.cancel(); endCapture() }
    }

    private func finish(_ image: CGImage, mode: CaptureMode, destination: CaptureDestination = .clipboard,
                        savedFile: URL? = nil, document: AnnotationDocument? = nil, backingScale: CGFloat? = nil, clipboardAlreadyDelivered: Bool = false) {
        let isWorkflow: Bool
        switch destination { case .workflow, .configureWorkflow: isWorkflow = true; default: isWorkflow = false }
        LocalUsage.shared.record("capture." + mode.rawValue)
        if destination == .text || destination == .table || destination == .code || destination == .qr { LocalUsage.shared.record("content.ocr") }
        endCapture(restoreFocus: destination != .file && destination != .beautify && !isWorkflow, restoreDashboard: destination != .beautify && !isWorkflow)
        let deliveryToken = textDeliveryToken, deliveryChange = imagePasteboard.changeCount
        switch destination {
        case .clipboard:
            if !clipboardAlreadyDelivered { copy(image, backingScale: backingScale ?? document?.backingScale ?? 1) }
        case .file:
            if let savedFile {
                LocalUsage.shared.record("output.file")
                if AppPreferences.standard.bool(forKey: "saveAlsoCopies") { copy(image, backingScale: backingScale ?? 1) }
                showToast(L10n.text("\(savedFile.pathExtension.uppercased()) 已保存"), symbol: "checkmark"); flash(L10n.text("长图已保存到文件。"))
            }
            else { NSApp.activate(ignoringOtherApps: true); save(image, parent: nil, backingScale: backingScale ?? document?.backingScale ?? 1) }
        case .pin: pin(image)
        case .beautify: showBeautifier(image)
        case .workflow(let id): showWorkflow(id: id, source: image, runOnOpen: true)
        case .configureWorkflow: showWorkflow(source: image)
        case .text, .table, .code, .qr: showToast(L10n.text("正在识别内容"), symbol: "text.viewfinder")
        case .recording, .recordingWindow, .scrolling, .scrollingHorizontal, .scrollingWindow: return
        }
        Task {
            do {
                let record = try await store.addAsync(image, mode: mode, document: document, backingScale: backingScale)
                selectedID = record.id
                if destination == .text || AppPreferences.standard.object(forKey: "autoOCRIndex") as? Bool != false {
                    recognize(record, copyAfter: destination == .text && textDeliveryToken == deliveryToken && imagePasteboard.changeCount == deliveryChange)
                }
                if destination == .table || destination == .code || destination == .qr {
                    Task {
                        do { try await deliverExtraction(image, destination: destination, token: deliveryToken, changeCount: deliveryChange) }
                        catch { flash(error.localizedDescription); showToast(L10n.text("未识别到内容"), symbol: "exclamationmark.triangle") }
                    }
                }
            } catch {
                // A history failure must not interrupt a successful clipboard capture.
                if destination == .text || destination == .table || destination == .code || destination == .qr {
                    Task {
                        do { try await deliverExtraction(image, destination: destination, token: deliveryToken, changeCount: deliveryChange) }
                        catch { flash(error.localizedDescription); showToast(L10n.text("识别失败"), symbol: "exclamationmark.triangle") }
                    }
                }
                flash(L10n.text("捕获已完成，但历史保存失败：\(error.localizedDescription)"))
            }
        }
    }

    private func endCapture(restoreFocus: Bool = true, restoreDashboard: Bool = true) {
        captureGeneration = UUID(); pendingCapture?.cancel(); pendingCapture = nil
        let inputReply = workflowInputCompletion; workflowInputCompletion = nil; workflowInputID = nil
        session?.close(); session = nil; isCapturing = false
        hiddenWindows.filter { !($0 is CaptureToastPanel) && (restoreDashboard || $0 !== dashboard) }.forEach { $0.orderFront(nil) }
        hiddenWindows.removeAll()
        if restoreFocus, let previousApplication {
            if previousApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                if restoreDashboard || previousKeyWindow !== dashboard { previousKeyWindow?.makeKeyAndOrderFront(nil) }
            } else { previousApplication.activate(options: []) }
        }
        previousApplication = nil
        previousKeyWindow = nil
        inputReply?(.failure(CancellationError()))
    }
    private func fail(_ error: Error) {
        let inputReply = workflowInputCompletion; workflowInputCompletion = nil; workflowInputID = nil
        endCapture()
        if case CaptureError.permission = CaptureEngine.normalizedCaptureError(error) {
            permission = false
            if let permissionWasDenied {
                inputReply?(.failure(error))
                permissionWasDenied()
                return
            }
        }
        if let inputReply { inputReply(.failure(error)); return }
        showDashboard(); notice = error.localizedDescription
    }
    func resizeLauncher() {
        // Read the hosting view after SwiftUI has laid out wrapped notice text.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.dashboard, let content = window.contentView else { return }
            let top = window.frame.maxY
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
            window.setFrameOrigin(CGPoint(x: window.frame.minX, y: top - window.frame.height))
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(CapturePanelGeometry.clamp(window.frame, to: screen.visibleFrame), display: true)
            }
        }
    }
    func flash(_ text: String) {
        noticeTask?.cancel(); notice = text
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { notice = nil; resizeLauncher() }
        }
        resizeLauncher()
    }

    private func beginRegionActivity(screen: NSScreen, rect: CGRect, destination: CaptureDestination, content: SCShareableContent, window: SCWindow? = nil, scrollDirection: ScrollDirection = .forward, scrollAxis: ScrollAxis = .vertical) {
        endCapture(restoreDashboard: false)
        isCapturing = true
        Task { [self] in
            defer { isCapturing = false }
            do {
                if destination == .recording {
                    showToast(L10n.text("准备开始录制"), symbol: "record.circle")
                    try await recorder.start(screen: screen, rect: rect, content: content, window: window)
                    showActivityHUD(RecordingHUD(recorder: recorder, stop: { [weak self] in Task { await self?.recorder.stop() } }, resize: { [weak self] size in self?.resizeRecordingHUD(size) }), size: RecordingHUD.contentSize(cameraEnabled: recorder.cameraEnabled, toolsVisible: recorder.drawing.toolsVisible), screen: screen, rect: rect)
                } else {
                    if destination != .scrollingWindow, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
                        lastScrollSelection = LastCaptureSelection(displayID: id, screenSize: screen.frame.size, rect: rect,
                                                                   identity: CaptureDisplayGeometry.identifier(id), backingScale: screen.backingScaleFactor)
                    }
                    if destination != .scrollingWindow { scrollRegionOutline.show(screen: screen, rect: rect) }
                    try await scrollCapture.start(screen: screen, rect: rect, content: content, automatic: ScrollAutomationAvailability.enabled && (destination == .scrollingWindow || automaticScrolling),
                                                  axis: destination == .scrollingHorizontal ? .horizontal : scrollAxis, direction: scrollDirection,
                                                  targetWindowID: window?.windowID, source: destination == .scrollingWindow ? .window : .region)
                    showActivityHUD(ScrollHUD(scroll: scrollCapture, finish: { [weak self] in Task { await self?.scrollCapture.finish() } }, save: { [weak self] in self?.saveScrollCapture() }, cancel: { [weak self] in
                        Task {
                            await self?.cancelScrollCapture()
                        }
                    }, edit: { [weak self] in Task { await self?.scrollCapture.finish(output: .editor) } }, onAutomaticChange: { [weak self] enabled in
                        guard let self, self.scrollCapture.setAutomatic(enabled) else { return }
                        if self.scrollCapture.source == .region {
                            self.automaticScrolling = enabled; AppPreferences.standard.set(enabled, forKey: "automaticScrolling")
                        }
                    }, resize: { [weak self] size in self?.resizeActivityHUD(size) }), size: ScrollHUD.initialSize, screen: screen, rect: rect, avoidSelection: true)
                }
            } catch {
                scrollRegionOutline.close()
                flash(error.localizedDescription); showDashboard()
            }
        }
    }
    @discardableResult func confirmScrollSelectionForDiagnostics() -> Bool { session?.confirmScrollForDiagnostics() ?? false }
    func cancelScrollCapture() async {
        await scrollCapture.cancel()
        if !scrollCapture.active { activityHUD?.close(); scrollRegionOutline.close() }
    }
    func saveScrollCapture() { ScrollFileDialog.present(for: scrollCapture) }
    private func resizeActivityHUD(_ size: CGSize) {
        guard let panel = activityHUD else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        var frame = CapturePanelGeometry.resized(panel.frame, size: size, visibleFrame: visible)
        if panel.title == L10n.text("长图实时预览"), scrollCapture.active, scrollCapture.source == .region, let screen = panel.screen,
           let rect = lastScrollSelection?.selection(for: screen) {
            let selection = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            if frame.intersects(selection) {
                frame = ScrollPreviewGeometry.panelFrame(selection: selection, visibleFrame: visible, size: size)
            }
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
    private func resizeRecordingHUD(_ size: CGSize) {
        guard let panel = activityHUD else { return }
        let old = panel.frame, visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? old
        panel.setFrame(CapturePanelGeometry.resized(old, size: size, visibleFrame: visible), display: true)
    }
    private func showActivityHUD<Content: View>(_ view: Content, size: CGSize, screen: NSScreen, rect: CGRect, avoidSelection: Bool = false) {
        activityHUD?.close()
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        let x = min(max(screen.visibleFrame.minX + 12, screen.frame.minX + rect.maxX - size.width), screen.visibleFrame.maxX - size.width - 12)
        let below = screen.frame.minY + rect.minY - size.height - 12
        let y = below >= screen.visibleFrame.minY ? below : min(screen.visibleFrame.maxY - size.height - 12, screen.frame.minY + rect.maxY + 12)
        if avoidSelection {
            panel.title = L10n.text("长图实时预览")
            let globalSelection = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            panel.setFrame(ScrollPreviewGeometry.panelFrame(selection: globalSelection, visibleFrame: screen.visibleFrame, size: size), display: true)
        } else {
            panel.setFrame(CapturePanelGeometry.clamp(CGRect(origin: CGPoint(x: x, y: y), size: size),
                                                      to: screen.visibleFrame), display: true)
        }
        activityHUD = panel
        if avoidSelection && scrollCapture.presentingAutomationPermission {
            panel.level = .normal
            panel.orderBack(nil)
        } else { panel.orderFrontRegardless() }
    }

    func importImage() {
        guard requirePermission?() != false else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let image = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                              width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
                              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else { throw CaptureError.message(L10n.text("图片无法读取，或超过 8000 万像素上限。")) }
                        return image
                    }.value
                    self?.openImportedImage(image)
                } catch { self?.flash(error.localizedDescription) }
            }
        }
    }
    func editClipboard() {
        guard requirePermission?() != false else { return }
        guard !isCapturing else { flash(L10n.text("请先完成当前截图。")); return }
        do {
            switch try ClipboardContent.read(imagePasteboard) {
            case .files(let urls):
                guard urls.count == 1 else { throw CaptureError.message(L10n.text("请一次复制一个文件进行编辑。")) }
                let url = urls[0]
                Task {
                    do { try await openClipboardFile(url) }
                    catch { flash(error.localizedDescription); showToast(error.localizedDescription, symbol: "exclamationmark.triangle") }
                }
            case .image(let image): try openClipboardImage(image)
            case .pdf(let data):
                guard data.count <= 100_000_000 else { throw CaptureError.message(L10n.text("PDF 无法读取，或超过 100 MB。")) }
                Task {
                    do {
                        let document = try await Task.detached(priority: .userInitiated) {
                            guard let document = PDFDocument(data: data) else { throw CaptureError.message(L10n.text("PDF 无法读取。")) }
                            return document
                        }.value
                        try openClipboardPDF(document, sourceData: data, name: L10n.text("剪贴板.pdf"))
                    } catch { flash(error.localizedDescription); showToast(error.localizedDescription, symbol: "exclamationmark.triangle") }
                }
            case .text(let text):
                guard text.utf8.count <= 10_000_000 else { throw CaptureError.message(L10n.text("剪贴板文本超过 10 MB。")) }
                openClipboardText(text)
            }
        } catch { flash(error.localizedDescription); showToast(error.localizedDescription, symbol: "exclamationmark.triangle") }
    }
    private func openClipboardImage(_ image: NSImage) throws {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), Double(cg.width) * Double(cg.height) <= 80_000_000 else { throw CaptureError.message(L10n.text("图片无法读取，或超过 8000 万像素。")) }
        openImportedImage(cg)
    }
    func openClipboardText(_ text: String, name: String = L10n.text("剪贴板.txt")) {
        clipboardEditors.removeAll { !$0.window.isVisible }
        clipboardEditors.append(ClipboardEditor(text: text, name: name, report: { [weak self] in self?.flash($0); self?.showToast($0, symbol: "info.circle") }))
    }
    private func openClipboardPDF(_ document: PDFDocument, sourceData: Data, name: String) throws {
        guard !document.isLocked, document.pageCount > 0 else { throw CaptureError.message(L10n.text("PDF 已加密或没有页面，请先解锁文件。")) }
        guard document.allowsCommenting else { throw CaptureError.message(L10n.text("这个 PDF 不允许标注。")) }
        clipboardEditors.removeAll { !$0.window.isVisible }
        clipboardEditors.append(ClipboardEditor(pdf: document, sourceData: sourceData, name: name, report: { [weak self] in self?.flash($0); self?.showToast($0, symbol: "info.circle") }, openText: { [weak self] in self?.openClipboardText($0, name: L10n.text("PDF 文字.txt")) }))
    }
    private func openClipboardFile(_ url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CaptureError.message(L10n.text("请选择一个本地文件，暂不支持文件夹。")) }
        guard let kind = ClipboardContent.kind(url) else { throw CaptureError.message(L10n.text("暂不支持这个文件类型：\(url.pathExtension.isEmpty ? url.lastPathComponent : url.pathExtension)。")) }
        switch kind {
        case .text:
            let text = try await Task.detached(priority: .userInitiated) { try ClipboardContent.loadText(url) }.value
            openClipboardText(text, name: url.lastPathComponent)
        case .pdf:
            guard (values.fileSize ?? 0) <= 100_000_000 else { throw CaptureError.message(L10n.text("PDF 无法读取，或超过 100 MB。")) }
            let (data, document) = try await Task.detached(priority: .userInitiated) {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 100_000_001) ?? Data()
                try Task.checkCancellation()
                guard data.count <= 100_000_000, let document = PDFDocument(data: data) else { throw CaptureError.message(L10n.text("PDF 无法读取，或超过 100 MB。")) }
                return (data, document)
            }.value
            try openClipboardPDF(document, sourceData: data, name: url.lastPathComponent)
        case .image:
            let image = try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else { throw CaptureError.message(L10n.text("图片无法读取，或超过 8000 万像素。")) }
            return image
            }.value
            openImportedImage(image)
        case .video: showVideo(url, imported: true)
        case .project:
            guard (values.fileSize ?? 0) <= 100_000_000 else { throw CaptureError.message(L10n.text("工程超过 100 MB。")) }
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (AnnotationDocument, CGImage) in
                let document = try AnnotationDocument(projectData: Data(contentsOf: url))
                guard let image = document.render() else { throw CaptureError.message(L10n.text("工程图片无法渲染。")) }
                return (document, image)
            }.value
            let record = try await store.addAsync(loaded.1, mode: .region, document: loaded.0); openEditor(record)
        }
    }
    private func openImportedImage(_ image: CGImage) {
        Task {
            do {
                let record = try await store.addAsync(image, mode: .region, backingScale: 1)
                openEditor(record)
                if AppPreferences.standard.object(forKey: "autoOCRIndex") as? Bool != false { recognize(record) }
            } catch { flash(L10n.text("导入失败：\(error.localizedDescription)")) }
        }
    }
    func importVideo() {
        guard requirePermission?() != false else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .deskVideoProject]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if ["deskvideo", "desktutorial"].contains(url.pathExtension.lowercased()) { self?.openPortableProject(url) }
            else { self?.showVideo(url, imported: true) }
        }
    }
    func importPortableProject() {
        guard requirePermission?() != false else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.deskVideoProject]; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { self?.openPortableProject(url) } }
    }
    func openPortableProject(_ input: URL) {
        guard requirePermission?() != false else { return }
        guard projectImportTask == nil else { flash(L10n.text("已有项目正在打开，可在进度窗口取消。")); projectImportPanel?.makeKeyAndOrderFront(nil); return }
        let panel = ProjectImportPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 110), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L10n.text("打开项目副本"); panel.isReleasedWhenClosed = false
        panel.cancelImport = { [weak self] in self?.projectImportTask?.cancel() }
        panel.contentView = NSHostingView(rootView: VStack(spacing: 12) { ProgressView(); Text(L10n.text("正在准备可编辑项目副本…")); Button(L10n.text("取消导入")) { [weak self] in self?.projectImportTask?.cancel() } }.padding())
        panel.center(); panel.makeKeyAndOrderFront(nil); projectImportPanel = panel
        projectImportTask = Task {
            defer { panel.cancelImport = nil; panel.close(); projectImportPanel = nil; projectImportTask = nil }
            do {
                let kind = try await Task.detached(priority: .utility) { try PortableProject.manifest(input).kind }.value
                guard kind == .video else { throw CaptureError.message(L10n.text("当前版本不提供步骤教程，原项目文件未改动。")) }
                let restored = try await PortableProject.restore(input, in: RecordingLibrary.directory)
                if Task.isCancelled { flash(L10n.text("项目副本已完成导入，未打开编辑窗口。")); return }
                if let video = restored.video { showVideo(video, imported: true) }
            } catch { flash(Task.isCancelled ? L10n.text("项目导入已取消") : L10n.text("项目未打开：\(error.localizedDescription)")) }
        }
    }
    func showVideo(_ url: URL, imported: Bool = false, cameraWasRequested: Bool = false) {
        videoWindows.removeAll { !$0.isVisible && !$0.isMiniaturized }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1120, height: 800)
        let window = VideoResultPanel(contentRect: VideoResultPanel.initialFrame(in: visible),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("视频编辑 — \(url.lastPathComponent)"); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 780, height: 540)
        window.isMovable = true
        window.setFrame(VideoResultPanel.initialFrame(in: visible), display: false)
        // A screen-only file must not be silently delivered as the camera composition.
        let copyOriginal = !imported && !cameraWasRequested && !FileManager.default.fileExists(atPath: RecordingCamera.url(for: url).path)
        var copiedOriginal = false
        if copyOriginal { imagePasteboard.clearContents(); copiedOriginal = imagePasteboard.writeObjects([url as NSURL]) }
        window.contentView = NSHostingView(rootView: VideoResultView(url: url, imported: imported, recordingWarning: imported ? nil : recorder.warning, copiedOriginal: copiedOriginal, cameraWasRequested: cameraWasRequested, close: { [weak window] in window?.performClose(nil) }, openProject: { [weak self] in self?.importPortableProject() }))
        videoWindow = window
        videoWindows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showToast(_ text: String, symbol: String) {
        toast?.close()
        let panel = CaptureToastPanel(contentRect: CGRect(x: 0, y: 0, width: 190, height: 46),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CaptureToast(text: text, symbol: symbol))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen { panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 95, y: screen.visibleFrame.minY + 36)) }
        panel.orderFrontRegardless(); toast = panel
        Task { [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(1400))
            panel?.close()
            if self?.toast === panel { self?.toast = nil }
        }
    }

    func waitForPendingHistoryImage() async { await historyImageTask?.value }
    private func prepareHistoryImage(_ record: CaptureRecord, deliver: @escaping (CGImage) -> Void) {
        historyImageTask?.cancel()
        let token = UUID(); historyImageToken = token
        let url = store.url(for: record), read = historyImageReader, loader = historyImageLoader
        let cameFromHistory = historyWindow?.isVisible == true
        func stillCurrent() -> Bool {
            !isCapturing && store.records.contains { $0.id == record.id && $0.filename == record.filename }
                && (!cameFromHistory || historyWindow?.isVisible == true)
        }
        flash(L10n.text("正在读取图片…"))
        historyImageTask = Task {
            defer { if historyImageToken == token { historyImageTask = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) { try await loader.load(url, using: read) }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard historyImageToken == token, stillCurrent() else { return }
                deliver(image)
            } catch is CancellationError { }
            catch {
                guard historyImageToken == token, !Task.isCancelled, stillCurrent() else { return }
                flash(L10n.text("图片无法读取：\(error.localizedDescription)"))
            }
        }
    }
    func waitForPendingImageCopy() async { _ = await imageCopyTask?.value }

    func copy(_ source: CGImage, backingScale: CGFloat = 1, feedback: ImageDeliveryFeedback? = nil) {
        copy(backingScale: backingScale, feedback: feedback, loadImage: { source })
    }
    @discardableResult
    private func copy(backingScale: CGFloat, feedback: ImageDeliveryFeedback? = nil,
                      loadImage: @escaping @Sendable () throws -> CGImage) -> Task<ImageDeliveryOutcome, Never> {
        invalidateTextDelivery()
        imageCopyTask?.cancel()
        let token = UUID(); imageCopyToken = token
        let logicalSize = AppPreferences.standard.bool(forKey: "clipboardLogicalSize")
        let pasteboard = imagePasteboard, expectedChange = pasteboard.changeCount
        let feedbackToken = feedback?.begin(L10n.text("正在复制图片…"), cancel: { [weak self] in
            guard self?.imageCopyToken == token else { return }
            self?.imageCopyTask?.cancel()
        })
        showToast(L10n.text("正在复制图片…"), symbol: "doc.on.clipboard")
        let job = Task { () -> ImageDeliveryOutcome in
            var outcome = ImageDeliveryOutcome.cancelled
            defer {
                if imageCopyToken == token { imageCopyTask = nil }
                if let feedbackToken { feedback?.complete(outcome, token: feedbackToken) }
                if imageCopyToken == token, case .failed(let message) = outcome {
                    flash(message); showToast(L10n.text("未能复制"), symbol: "exclamationmark.triangle")
                }
            }
            var attemptedWrite = false
            do {
                guard imageCopyToken == token else { return outcome }
                guard pasteboard.changeCount == expectedChange else { outcome = .failed(L10n.text("剪贴板已有新的内容，未覆盖。")); return outcome }
                let encoded = try await ClipboardImageEncoding.encode(logicalSize: logicalSize, backingScale: backingScale, loadImage: loadImage)
                try Task.checkCancellation()
                guard imageCopyToken == token else { return outcome }
                guard pasteboard.changeCount == expectedChange else { outcome = .failed(L10n.text("剪贴板已有新的内容，未覆盖。")); return outcome }
                attemptedWrite = true
                pasteboard.clearContents()
                guard pasteboard.setData(encoded.png, forType: .png) else { throw CaptureError.message(L10n.text("无法写入剪贴板，请重新复制。")) }
                if let tiff = encoded.tiff { pasteboard.setData(tiff, forType: .tiff) }
                outcome = .copied
                onImageCopyCompleted?()
                LocalUsage.shared.record("output.clipboard")
                flash(L10n.text("图片已复制，可以直接粘贴。")); showToast(L10n.text("已复制"), symbol: "checkmark")
            } catch is CancellationError { }
            catch {
                guard imageCopyToken == token, !Task.isCancelled,
                      attemptedWrite || pasteboard.changeCount == expectedChange else { return outcome }
                outcome = .failed(L10n.text("复制失败：\(error.localizedDescription)"))
            }
            return outcome
        }
        imageCopyTask = job
        return job
    }
    func copy(_ record: CaptureRecord) {
        let url = store.url(for: record)
        copy(backingScale: record.backingScale ?? 1, loadImage: { try CaptureImageRead.load(url, maximumFileBytes: 400_000_000) })
    }
    func save(_ record: CaptureRecord) {
        prepareHistoryImage(record) { [weak self] image in self?.save(image, parent: self?.historyWindow, backingScale: record.backingScale ?? 1) }
    }
    func save(_ image: CGImage, parent: NSWindow?, backingScale: CGFloat = 1, feedback: ImageDeliveryFeedback? = nil) {
        let key = parent.map(ObjectIdentifier.init) ?? ObjectIdentifier(self)
        guard imageFileExports[key] == nil else { flash(L10n.text("当前窗口已有图片保存操作。")); return }
        let operation = ImageFileExportOperation(parent: parent), panel = operation.panel
        let feedbackToken = feedback?.begin(L10n.text("选择保存位置…"), cancel: { [weak operation] in operation?.cancel() })
        var outcome = ImageDeliveryOutcome.cancelled
        imageFileExports[key] = operation
        imageExportStatus[key] = L10n.text("选择保存位置…")
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "DeskCapture \(formatter.string(from: Date())).png"
        let finish = { [weak self] in
            operation.finish()
            if let feedbackToken { feedback?.complete(outcome, token: feedbackToken) }
            guard self?.imageFileExports[key] === operation else { return }
            self?.imageFileExports.removeValue(forKey: key)
            self?.imageExportStatus.removeValue(forKey: key)
        }
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard !operation.cancelled, response == .OK, let url = panel.url else { finish(); return }
            self?.imageExportStatus[key] = L10n.text("正在保存图片…")
            if let feedbackToken { feedback?.update(L10n.text("正在保存图片…"), token: feedbackToken) }
            // Preferences belong to the requested delivery, not a later UI state.
            let copiesAfterSaving = AppPreferences.standard.bool(forKey: "saveAlsoCopies")
            operation.task = Task { @MainActor [weak self] in
                defer { finish() }
                do {
                    let worker = Task.detached(priority: .userInitiated) { try CaptureImageExport.write(image, to: url) }
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, !operation.cancelled else { return }
                    outcome = .saved(url)
                    LocalUsage.shared.record("output.file")
                    if copiesAfterSaving { self?.copy(image, backingScale: backingScale) }
                    self?.flash(L10n.text("\(url.pathExtension.uppercased()) 已保存。"))
                } catch is CancellationError { }
                catch {
                    if !operation.cancelled {
                        outcome = .failed(L10n.text("保存失败：\(error.localizedDescription)"))
                        self?.flash(L10n.text("保存失败：\(error.localizedDescription)"))
                    }
                }
            }
        }
        SavePanelPresentation.begin(panel, parent: parent, completion: completion)
    }

    func recognize(_ record: CaptureRecord, copyAfter: Bool = false) {
        if let text = store.records.first(where: { $0.id == record.id })?.recognizedText {
            if copyAfter { copyText(text) }; return
        }
        if copyAfter {
            invalidateTextDelivery()
            pendingTextCopies[record.id] = (textDeliveryToken, imagePasteboard.changeCount)
        }
        guard !recognitionIDs.contains(record.id) else { return }
        let source = store.url(for: record)
        recognitionErrors[record.id] = nil
        recognitionIDs.insert(record.id); isRecognizing = true
        Task {
            defer { recognitionIDs.remove(record.id); pendingTextCopies.removeValue(forKey: record.id); isRecognizing = !recognitionIDs.isEmpty }
            do {
                let image = try await Task.detached(priority: .userInitiated) { try CaptureImageRead.load(source) }.value
                let text: String
                if let recognizer = textRecognizerForDiagnostics { text = try await recognizer(image) }
                else { text = try await CaptureEngine.recognize(image) }
                guard !Task.isCancelled, let current = store.records.first(where: { $0.id == record.id }), current.recognizedText == nil else { return }
                try await store.setTextAsync(text, for: record.id, onlyIfMissing: true)
                guard store.records.first(where: { $0.id == record.id })?.recognizedText == text else { return }
                if let pending = pendingTextCopies.removeValue(forKey: record.id), pending.token == textDeliveryToken, pending.changeCount == imagePasteboard.changeCount {
                    if text.isEmpty { flash(L10n.text("没有识别到文字，试试更清晰或更大的区域。")) }
                    else { copyText(text) }
                }
            } catch {
                pendingTextCopies.removeValue(forKey: record.id)
                recognitionErrors[record.id] = error.localizedDescription
                flash(L10n.text("文字识别失败：\(error.localizedDescription)"))
            }
        }
    }
    var workflowClipboardRevision: Int { imagePasteboard.changeCount }
    func copyWorkflowText(_ text: String, expectedChange: Int) throws {
        guard !text.isEmpty else { throw CaptureError.message(L10n.text("没有识别到可复制的文字。")) }
        guard imagePasteboard.changeCount == expectedChange else { throw CaptureError.message(L10n.text("剪贴板已有新的内容，结果保留在预览中。")) }
        invalidateTextDelivery(); imageCopyTask?.cancel(); imageCopyToken = UUID()
        imagePasteboard.clearContents()
        guard imagePasteboard.setString(text, forType: .string) else { throw CaptureError.message(L10n.text("无法写入剪贴板。")) }
        showToast(L10n.text("文字已复制"), symbol: "checkmark")
    }
    func copyText(_ text: String) {
        guard !text.isEmpty else { flash(L10n.text("没有可复制的文字。")) ; return }
        invalidateTextDelivery(); imageCopyTask?.cancel(); imageCopyToken = UUID()
        imagePasteboard.clearContents(); imagePasteboard.setString(text, forType: .string)
        flash(L10n.text("文字已复制，识别过程在本机完成。"))
        showToast(L10n.text("文字已复制"), symbol: "checkmark")
    }
    private func invalidateTextDelivery() { textDeliveryToken = UUID(); pendingTextCopies.removeAll() }
    func copyReviewedTable(_ output: OCRTableExports) {
        invalidateTextDelivery(); imageCopyTask?.cancel(); imageCopyToken = UUID()
        imagePasteboard.clearContents()
        imagePasteboard.setString(output.tsv, forType: .string)
        imagePasteboard.setData(output.html, forType: .html)
        flash(L10n.text("已复制HTML合并表格及扁平TSV；粘贴效果取决于目标应用。"))
        showToast(L10n.text("表格已复制"), symbol: "checkmark")
    }
    private func showTableReview(_ image: CGImage, table: OCRTableResult) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.text("表格结构复核 — \(AppIdentity.name)"); window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OCRTableReviewView(source: image, table: table, app: self, close: { [weak window] in window?.close() }))
        editors.removeAll { !$0.isVisible && !$0.isMiniaturized }; editors.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func deliverExtraction(_ image: CGImage, destination: CaptureDestination, token: UUID, changeCount: Int) async throws {
        if destination == .table, #available(macOS 26.0, *) {
            let table = try await CaptureEngine.extractTable(image)
            guard !Task.isCancelled, token == textDeliveryToken, changeCount == imagePasteboard.changeCount else { return }
            if table.requiresReview { showTableReview(image, table: table); return }
            let text = try await Task.detached { try Task.checkCancellation(); return table.tsv }.value
            guard !Task.isCancelled, token == textDeliveryToken, changeCount == imagePasteboard.changeCount else { return }
            copyText(text); return
        }
        let text = try await CaptureEngine.extract(image, destination: destination)
        guard !Task.isCancelled, token == textDeliveryToken, changeCount == imagePasteboard.changeCount else { return }
        copyText(text)
    }

    func openEditor(_ record: CaptureRecord) {
        let url = store.url(for: record), projectURL = store.projectURL(for: record)
        flash(L10n.text("正在打开图片…"))
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (AnnotationDocument, String?) in
                    if let projectURL {
                        do { return (try AnnotationDocument(projectData: Data(contentsOf: projectURL)), nil) }
                        catch {
                            let projectError = error.localizedDescription
                            let image = try CaptureImageRead.load(url)
                            return (AnnotationDocument(image: image), L10n.text("工程读取失败，已打开最终图片：\(projectError)"))
                        }
                    }
                    return (AnnotationDocument(image: try CaptureImageRead.load(url)), nil)
                }.value
                let document = loaded.0
                if let warning = loaded.1 { flash(warning) }
                document.backingScale = record.backingScale ?? document.backingScale
                let window = ImageEditorWindow(document: document, coordinator: self)
                window.title = "\(record.title) — \(AppIdentity.name)"
                window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
                window.backgroundColor = .clear; window.isOpaque = false; window.isReleasedWhenClosed = false
                window.contentMinSize = CGSize(width: 760, height: 540)
                window.contentView = NSHostingView(rootView: EditorView(app: self, store: store, document: document, record: record, parent: window))
                editors.removeAll { !$0.isVisible && !$0.isMiniaturized }
                editors.append(window)
                window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            } catch { flash(L10n.text("图片无法读取：\(error.localizedDescription)")) }
        }
    }

    func saveEdited(_ image: CGImage, document: AnnotationDocument? = nil,
                    completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        let key = document.map(ObjectIdentifier.init) ?? ObjectIdentifier(self)
        guard !imageHistorySaves.contains(key) else {
            completion?(.failure(CaptureError.message(L10n.text("当前图片正在存入历史副本，请稍候。"))))
            return
        }
        let snapshot = document.map(CaptureProjectSnapshot.init)
        imageHistorySaves.insert(key)
        Task {
            defer { imageHistorySaves.remove(key) }
            do {
                let record = try await store.addAsync(image, mode: .region, projectSnapshot: snapshot)
                selectedID = record.id; recognize(record); flash(L10n.text("可编辑副本已加入历史。"))
                completion?(.success(()))
            } catch {
                flash(L10n.text("保存副本失败：\(error.localizedDescription)"))
                completion?(.failure(error))
            }
        }
    }
    func showWorkflow(id: UUID? = nil, source: CGImage? = nil, runOnOpen: Bool = false) {
        guard requirePermission?() != false else { return }
        Task {
            do { try await openWorkflow(id: id, source: source, runOnOpen: runOnOpen) }
            catch { showDashboard(); flash(L10n.text("无法打开流程：\(error.localizedDescription)")); showToast(L10n.text("流程无法打开"), symbol: "exclamationmark.triangle") }
        }
    }
    func openWorkflow(id: UUID? = nil, source: CGImage? = nil, runOnOpen: Bool = false) async throws {
        guard requirePermission?() != false else { throw CaptureError.permission }
        let recipe: LocalWorkflowRecipe
        if let id {
            guard let saved = try await LocalWorkflowLibrary.shared.list().first(where: { $0.id == id }) else { throw CaptureError.message(L10n.text("没有找到该本地流程，请先保存后再使用启动链接。")) }
            recipe = saved
        } else { recipe = LocalWorkflowView.newRecipe() }
        try Task.checkCancellation()
        let window = LocalWorkflowWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("流程 — \(AppIdentity.name)"); window.isReleasedWhenClosed = false
        window.contentMinSize = StudioMetrics.workspaceMinimum
        window.contentView = NSHostingView(rootView: LocalWorkflowView(app: self, recipe: recipe, source: source, runOnOpen: runOnOpen, parent: { [weak window] in window }, close: { [weak window] in window?.close() }))
        workflowWindow = window
        editors.removeAll { !$0.isVisible && !$0.isMiniaturized }; editors.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func workflow(_ record: CaptureRecord) {
        let url = store.url(for: record)
        Task {
            do {
                let image = try await Task.detached { try CaptureImageRead.load(url) }.value
                guard store.records.contains(where: { $0.id == record.id }) else { return }
                showWorkflow(source: image)
            } catch { flash(L10n.text("无法载入流程图片：\(error.localizedDescription)")) }
        }
    }

    func showBeautifier(_ image: CGImage? = nil, watermark: ImageWatermark? = nil) {
        guard requirePermission?() != false else { return }
        let window = BeautifyWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.text("图片美化 — \(AppIdentity.name)")
        window.contentMinSize = StudioMetrics.workspaceMinimum
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        let feedback = ImageDeliveryFeedback()
        window.contentView = NSHostingView(rootView: BeautifyWorkspaceView(store: store, pasteboard: imagePasteboard, source: image, watermark: watermark,
            copy: { [weak self] in self?.copy($0, feedback: feedback) },
            save: { [weak self, weak window] in self?.save($0, parent: window, feedback: feedback) },
            close: { [weak window] in window?.close() },
            isPresented: { [weak window] in window?.isVisible == true || window?.isMiniaturized == true }, feedback: feedback))
        editors.removeAll { !$0.isVisible && !$0.isMiniaturized }; editors.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func beautify(_ record: CaptureRecord) {
        prepareHistoryImage(record) { [weak self] image in self?.showBeautifier(image) }
    }
    func transform(_ record: CaptureRecord) {
        prepareHistoryImage(record) { [weak self] image in self?.showTransform(image) }
    }
    func showTransform(_ image: CGImage) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("图片变换与拼图 — \(AppIdentity.name)")
        window.contentMinSize = StudioMetrics.workspaceMinimum
        window.backgroundColor = .windowBackgroundColor; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ImageTransformView(source: image,
            copy: { [weak self] in self?.copy($0) }, save: { [weak self, weak window] in self?.save($0, parent: window) },
            close: { [weak window] in window?.close() }, cleanup: { [weak self] in self?.showCleanup($0) }))
        editors.removeAll { !$0.isVisible && !$0.isMiniaturized }; editors.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func cleanup(_ record: CaptureRecord) {
        let source = store.url(for: record)
        prepareCleanup({ try CaptureImageRead.load(source) }, isCurrent: { [weak self] in self?.store.records.contains(record) == true },
                       mode: CaptureMode(rawValue: record.mode) ?? .region, backingScale: record.backingScale ?? 1)
    }
    func showCleanup(_ document: AnnotationDocument, parent: NSWindow, mode: CaptureMode = .region) {
        document.commitPendingText?()
        let image = document.original, marks = document.marks, revision = document.renderRevision
        prepareCleanup({
            let snapshot = AnnotationDocument(image: image); snapshot.marks = marks
            guard let result = snapshot.render() else { throw CaptureError.message(L10n.text("无法生成当前标注图片。")) }
            return result
        }, isCurrent: { [weak document, weak parent] in document?.renderRevision == revision && parent?.isVisible == true },
           mode: mode, backingScale: document.backingScale)
    }
    private func prepareCleanup(_ work: @escaping () throws -> CGImage, isCurrent: @escaping () -> Bool,
                                mode: CaptureMode = .region, backingScale: CGFloat = 1) {
        cleanupPreparationTask?.cancel(); cleanupPreparationToken = UUID()
        let token = cleanupPreparationToken
        flash(L10n.text("正在打开裁剪与清理…"))
        cleanupPreparationTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
                let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard cleanupPreparationToken == token, isCurrent() else { return }
                cleanupPreparationTask = nil; showCleanup(image, mode: mode, backingScale: backingScale)
            } catch is CancellationError { }
            catch {
                guard cleanupPreparationToken == token else { return }
                cleanupPreparationTask = nil; flash(L10n.text("无法打开图片：\(error.localizedDescription)"))
            }
        }
    }
    func showCleanup(_ image: CGImage, mode: CaptureMode = .region, backingScale: CGFloat = 1) {
        let window = ImageCleanupWindow(source: image)
        window.contentView = NSHostingView(rootView: ImageCleanupView(model: window.model,
            copy: { [weak self] in self?.copy($0) }, save: { [weak self, weak window] in self?.save($0, parent: window) },
            close: { [weak window] in window?.close() }, edit: { [weak self] result in
                guard let self else { throw CancellationError() }
                try Task.checkCancellation()
                let record = try await self.store.addAsync(result, mode: mode, backingScale: backingScale)
                self.selectedID = record.id
                self.openEditor(record)
            }))
        editors.removeAll { !$0.isVisible && !$0.isMiniaturized }; editors.append(window)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func share(_ record: CaptureRecord) {
        guard let view = historyWindow?.contentView else { return }
        NSSharingServicePicker(items: [store.url(for: record)]).show(relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 50, width: 1, height: 1),
                                                                  of: view, preferredEdge: .minY)
    }
    func exportProject(_ record: CaptureRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("DeskCapture 工程.deskcap")
        panel.begin { [weak self] response in
            guard response == .OK, let chosen = panel.url, let self else { return }
            let project = self.store.projectURL(for: record), source = self.store.url(for: record)
            let output = chosen.pathExtension.lowercased() == "deskcap" ? chosen : chosen.appendingPathExtension("deskcap")
            Task {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let data: Data
                        if let project { data = try Data(contentsOf: project) }
                        else { data = try AnnotationDocument(image: CaptureImageRead.load(source)).projectData() }
                        try data.write(to: output, options: .atomic)
                    }.value
                    self.flash(L10n.text("工程文件已保存。"))
                } catch { self.flash(L10n.text("工程导出失败：\(error.localizedDescription)")) }
            }
        }
    }
    func importProject() {
        guard requirePermission?() != false else { return }
        let panel = NSOpenPanel(); panel.message = L10n.text("选择 .deskcap 工程文件")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) { () throws -> (AnnotationDocument, CGImage) in
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100_000_000 else { throw CaptureError.message(L10n.text("工程超过 100 MB。")) }
                        let document = try AnnotationDocument(projectData: Data(contentsOf: url))
                        guard let image = document.render() else { throw CaptureError.message(L10n.text("工程图片无法渲染。")) }
                        return (document, image)
                    }.value
                    let record = try await self.store.addAsync(loaded.1, mode: .region, document: loaded.0)
                    self.selectedID = record.id; self.flash(L10n.text("工程已导入历史，可继续编辑。"))
                } catch { self.flash(L10n.text("工程导入失败：\(error.localizedDescription)")) }
            }
        }
    }
    func clearHistory() async throws {
        defer { if !store.records.contains(where: { $0.id == selectedID }) { selectedID = nil } }
        try await store.clearAllAsync()
        flash(L10n.text("已清空全部截图历史。"))
    }

    func delete(_ record: CaptureRecord) {
        Task {
            do { _ = try await store.removeBatch([record.id]); if selectedID == record.id { selectedID = nil }; flash(L10n.text("已移入可恢复批次，可在历史的批量整理中恢复。")) }
            catch { flash(L10n.text("移除失败：\(error.localizedDescription)")) }
        }
    }
    func pin(_ image: CGImage) {
        LocalUsage.shared.record("output.pin")
        let ratio = min(500 / CGFloat(image.width), 360 / CGFloat(image.height), 1)
        let size = CGSize(width: max(180, CGFloat(image.width) * ratio), height: max(80, CGFloat(image.height) * ratio))
        let panel = PinnedImagePanel(contentRect: CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height + 30)), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.minSize = CGSize(width: 180, height: 110)
        panel.title = L10n.text("贴到屏幕")
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(rootView: PinView(image: NSImage(cgImage: image, size: size), close: { [weak panel] in panel?.close() },
            setOpacity: { [weak panel] in panel?.alphaValue = $0 }, lock: { [weak self, weak panel] in
                panel?.ignoresMouseEvents = true; self?.flash(L10n.text("钉图已穿透锁定。从菜单栏选择“解锁所有钉图”恢复操作。"))
            }))
        pins.removeAll { !$0.isVisible }; pins.append(panel)
        panel.center(); panel.makeKeyAndOrderFront(nil); flash(L10n.text("已贴到屏幕；拖动图片移动，双击关闭。"))
    }
    func unlockPins() { pins.forEach { $0.ignoresMouseEvents = false }; flash(L10n.text("钉图已解锁。")) }
}
