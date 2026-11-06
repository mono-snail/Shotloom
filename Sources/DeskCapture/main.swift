import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import Combine

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var coordinator: AppCoordinator!
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenuController!
    private var fallbackMenu: NSMenu!
    let launchGuide = StatusItemGuideController()
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingOpenURLs: [URL] = []
    private var diagnosticPasteboard: NSPasteboard?
    private var permissionGate: ScreenCapturePermissionController?
    private let appInstance = AppInstanceController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appInstance.begin { [weak self] in self?.finishLaunching() }
    }

    private func finishLaunching() {
        if CommandLine.arguments.contains("--ocr-reference-benchmark") { Task { await OCRReferenceBenchmark().run() }; return }
        if CommandLine.arguments.contains("--ocr-reference-editor") {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] ?? NSTemporaryDirectory())
                .appendingPathComponent("ocr-editor-\(UUID())")
            let board = NSPasteboard(name: .init("DeskCapture-OCR-review-\(UUID())"))
            coordinator = AppCoordinator(store: CaptureStore(directory: root), imagePasteboard: board, registerHotKeys: false)
            Task {
                do {
                    let image = try await Task.detached { try OCRReferenceCorpus.render(OCRReferenceCorpus.samples[0]) }.value
                    let record = try await coordinator.store.addAsync(image, mode: .region)
                    coordinator.openEditor(record)
                } catch { NSApp.terminate(nil) }
            }
            return
        }
        if CommandLine.arguments.contains("--capture-ui-benchmark") { Task { await WorkflowBenchmarks().runCaptureUI() }; return }
        if CommandLine.arguments.contains("--workflow-benchmark") { Task { await WorkflowBenchmarks().run() }; return }
        AppAppearance.apply(AppPreferences.standard.string(forKey: "appearanceMode") ?? "system")
        if ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] != nil {
            let proposed = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_PASTEBOARD"] ?? ""
            let name = proposed.hasPrefix("DeskCapture-QA-") && proposed.count <= 160 ? proposed : "DeskCapture-Diagnostic-\(UUID())"
            let board = NSPasteboard(name: .init(name)); diagnosticPasteboard = board
            coordinator = AppCoordinator(imagePasteboard: board, registerHotKeys: false)
            if let raw = ProcessInfo.processInfo.environment["DESKCAPTURE_SCROLL_SELECTION"] {
                let values = raw.split(separator: ",").compactMap { Double($0) }
                if values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 {
                    coordinator.scrollSelectionForDiagnostics = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                }
            }
        } else { coordinator = AppCoordinator() }
        if ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] == nil && !CommandLine.arguments.contains("--quality-diagnostic") {
            Task.detached(priority: .utility) { DeskCaptureAppShortcuts.updateAppShortcutParameters() }
        }
        if CommandLine.arguments.contains("--quality-diagnostic") { Task { await QualityDiagnostics().run() }; return }
        if CommandLine.arguments.contains("--capture-diagnostic") {
            runCaptureDiagnostic(); return
        }
        if CommandLine.arguments.contains("--studio-export-diagnostic") { runStudioDiagnostic(); return }
        if CommandLine.arguments.contains("--recording-smoke-test") { runRecordingSmokeTest(); return }
        if CommandLine.arguments.contains("--camera-recording-smoke-test") { runCameraRecordingSmokeTest(); return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppBrandIcon.menuBar(accessibilityDescription: L10n.text("\(AppIdentity.name) 主菜单"))
        statusItem.button?.toolTip = L10n.text("\(AppIdentity.name) 主菜单（右键打开系统菜单）")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: L10n.text("快捷面板"), action: #selector(showDashboard), keyEquivalent: "")
        open.target = self; menu.addItem(open); menu.addItem(.separator())
        for (index, mode) in CaptureMode.allCases.enumerated() {
            let item = NSMenuItem(title: mode.title, action: #selector(capture(_:)), keyEquivalent: "")
            item.target = self; item.tag = 100 + index
            item.isHidden = !mode.isAvailable(screenCount: coordinator.screenCount)
            menu.addItem(item)
        }
        let upwardScrolling = NSMenuItem(title: L10n.text("向上长截图"), action: #selector(captureUpwardScroll), keyEquivalent: "")
        upwardScrolling.target = self; upwardScrolling.tag = 917; menu.addItem(upwardScrolling)
        let windowRecording = NSMenuItem(title: L10n.text("窗口录屏…"), action: #selector(recordWindow), keyEquivalent: "")
        windowRecording.target = self; windowRecording.tag = 911; menu.addItem(windowRecording)
        let repeatArea = NSMenuItem(title: L10n.text("重新截取上次区域"), action: #selector(repeatArea), keyEquivalent: "")
        repeatArea.target = self; repeatArea.tag = 910; menu.addItem(repeatArea)
        let delayed = NSMenuItem(title: L10n.text("定时截图"), action: nil, keyEquivalent: "")
        let delayedMenu = NSMenu(); delayed.submenu = delayedMenu
        for seconds in [3, 5, 10] {
            let item = NSMenuItem(title: L10n.text("\(seconds) 秒后截图"), action: #selector(delayedCapture(_:)), keyEquivalent: "")
            item.target = self; item.tag = seconds; delayedMenu.addItem(item)
        }
        menu.addItem(delayed)
        let unlock = NSMenuItem(title: L10n.text("解锁所有钉图"), action: #selector(unlockPins), keyEquivalent: "")
        unlock.target = self; menu.addItem(unlock)
        let stopRecording = NSMenuItem(title: L10n.text("结束录屏并保存"), action: #selector(stopRecording), keyEquivalent: "")
        stopRecording.tag = 901; stopRecording.target = self; menu.addItem(stopRecording)
        let pauseRecording = NSMenuItem(title: L10n.text("暂停 / 继续录屏"), action: #selector(pauseRecording), keyEquivalent: "")
        pauseRecording.tag = 902; pauseRecording.target = self; menu.addItem(pauseRecording)
        let stopScrolling = NSMenuItem(title: L10n.text("完成长截图并复制"), action: #selector(stopScrolling), keyEquivalent: "")
        stopScrolling.tag = 903; stopScrolling.target = self; menu.addItem(stopScrolling)
        let saveScrolling = NSMenuItem(title: L10n.text("完成长截图并保存文件…"), action: #selector(saveScrolling), keyEquivalent: "")
        saveScrolling.tag = 904; saveScrolling.target = self; menu.addItem(saveScrolling)
        menu.addItem(.separator())
        let clipboard = NSMenuItem(title: L10n.text("编辑剪贴板…"), action: #selector(editClipboard), keyEquivalent: "")
        clipboard.target = self; menu.addItem(clipboard)
        let beautify = NSMenuItem(title: L10n.text("图片美化…"), action: #selector(showBeautifier), keyEquivalent: "")
        beautify.target = self; menu.addItem(beautify)
        let history = NSMenuItem(title: L10n.text("捕获历史"), action: #selector(showHistory), keyEquivalent: "")
        history.target = self; menu.addItem(history)
        let device = NSMenuItem(title: L10n.text("iPhone / iPad 与设备录制…"), action: #selector(showDevices), keyEquivalent: "")
        device.target = self; menu.addItem(device)
        let recordings = NSMenuItem(title: L10n.text("录屏素材与分段恢复"), action: #selector(showRecordings), keyEquivalent: "")
        recordings.target = self; menu.addItem(recordings)
        let editVideo = NSMenuItem(title: L10n.text("打开视频进行成片编辑…"), action: #selector(importVideo), keyEquivalent: "")
        editVideo.target = self; menu.addItem(editVideo)
        let settings = NSMenuItem(title: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let support = NSMenuItem(title: L10n.translate("Support and Feedback…"), action: #selector(openSupport), keyEquivalent: "")
        support.target = self; menu.addItem(support)
        let updates = NSMenuItem(title: L10n.text("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self; menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.text("退出 \(AppIdentity.name)"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        menu.delegate = self; fallbackMenu = menu
        statusMenu = StatusMenuController(app: coordinator) { [weak self] action in self?.performStatusAction(action) }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleStatusMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        coordinator.recorder.$elapsed.sink { [weak self] elapsed in
            guard let self else { return }
            if self.coordinator.recorder.state != .idle {
                self.statusItem.length = NSStatusItem.variableLength
                self.statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: L10n.text("正在录屏"))
                self.statusItem.button?.title = String(format: " %02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
                self.statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            }
        }.store(in: &subscriptions)
        coordinator.recorder.$state.sink { [weak self] state in
            guard let self, state == .idle else { return }
            self.statusItem.length = NSStatusItem.squareLength; self.statusItem.button?.title = ""
            self.statusItem.button?.image = AppBrandIcon.menuBar(accessibilityDescription: L10n.text("\(AppIdentity.name) 主菜单"))
        }.store(in: &subscriptions)
        makeApplicationMenu()
        coordinator.updates.blockReason = { [weak coordinator] in coordinator?.updateBlockReason }
        let gate = ScreenCapturePermissionController(app: coordinator) { [weak self] in self?.finishPermissionSetup() }
        permissionGate = gate
        coordinator.requirePermission = { [weak gate] in gate?.allowEntry() ?? true }
        coordinator.permissionWasDenied = { [weak gate] in gate?.requireSetup() }
        if AppPreferences.isInteractivePermissionReview { gate.requireSetup() }
        else { gate.start() }
    }
    private func finishPermissionSetup() {
        coordinator.updates.startIfConfigured()
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs; pendingOpenURLs = []
            self.application(NSApp, open: urls)
            return
        }
        if CommandLine.arguments.contains("--show-status-menu"), let button = statusItem.button {
            DispatchQueue.main.async { [weak self] in self?.statusMenu.toggle(relativeTo: button) }
        }
        if CommandLine.arguments.contains("--show-panel") {
            coordinator.showDashboard()
        } else if !CommandLine.arguments.contains("--show-status-menu") {
            showLaunchGuide()
        }
    }
    @objc private func toggleStatusMenu() {
        guard permissionGate?.allowEntry() != false, let button = statusItem.button else { return }
        launchGuide.dismiss()
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusMenu.close()
            statusItem.menu = fallbackMenu
            button.performClick(nil)
            statusItem.menu = nil
        } else { statusMenu.toggle(relativeTo: button) }
    }
    private func performStatusAction(_ action: StatusMenuAction) {
        switch action {
        case .capture(let mode): coordinator.start(mode)
        case .upwardScroll: captureUpwardScroll()
        case .repeatRegion: coordinator.start(.region, repeatSelection: true)
        case .delayedCapture(let seconds): coordinator.start(.region, delay: seconds)
        case .recordWindow: recordWindow()
        case .dashboard: showDashboard()
        case .history: showHistory()
        case .clipboard: editClipboard()
        case .beautify: showBeautifier()
        case .workflow: coordinator.showWorkflow()
        case .recordings: showRecordings()
        case .video: importVideo()
        case .devices: showDevices()
        case .unlockPins: unlockPins()
        case .settings: showSettings()
        case .support: openSupport()
        case .updates: checkForUpdates()
        case .quit: quit()
        case .stopRecording: stopRecording()
        case .pauseRecording: pauseRecording()
        case .copyScrolling: stopScrolling()
        case .saveScrolling: saveScrolling()
        case .cancelScrolling: Task { await coordinator.cancelScrollCapture() }
        }
    }
    func makeApplicationMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        appMenu.addItem(withTitle: L10n.text("主菜单"), action: #selector(toggleStatusMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L10n.text("快捷面板"), action: #selector(showDashboard), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L10n.text("设置…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L10n.text("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("隐藏 \(AppIdentity.name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.text("退出 \(AppIdentity.name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: L10n.text("编辑")); editItem.submenu = editMenu; main.addItem(editItem)
        editMenu.addItem(withTitle: L10n.text("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.text("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        let editClipboardItem = editMenu.addItem(withTitle: L10n.text("编辑剪贴板…"), action: #selector(editClipboard), keyEquivalent: "v")
        editClipboardItem.target = self; editClipboardItem.keyEquivalentModifierMask = [.command, .shift]
        let beautifyItem = editMenu.addItem(withTitle: L10n.text("图片美化…"), action: #selector(beautifyCurrentImage), keyEquivalent: "b")
        beautifyItem.target = self; beautifyItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let helpItem = NSMenuItem(); let helpMenu = NSMenu(title: L10n.text("帮助"))
        helpItem.submenu = helpMenu; main.addItem(helpItem)
        helpMenu.addItem(withTitle: L10n.text("Shotloom 支持…"), action: #selector(openSupport), keyEquivalent: "").target = self
        helpMenu.addItem(withTitle: L10n.translate("Privacy Policy…"), action: #selector(openPrivacyPolicy), keyEquivalent: "").target = self
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = main
    }
    @objc private func editClipboard() { coordinator.editClipboard() }
    @objc private func beautifyCurrentImage() {
        if let editor = NSApp.keyWindow as? ImageEditorWindow {
            editor.requestBeautification()
        } else if let editor = NSApp.keyWindow?.sheetParent as? ImageEditorWindow {
            // Consume the editor command while its modal sheet owns focus.
            editor.requestBeautification()
        } else {
            coordinator.showBeautifier()
        }
    }
    @objc private func showBeautifier() { coordinator.showBeautifier() }
    @objc private func showDevices() { coordinator.showDevices() }
    @objc private func captureUpwardScroll() { coordinator.start(.scrolling, scrollDirection: .reverse) }
    @objc private func recordWindow() { coordinator.start(.window, recordWindow: true) }
    @objc private func showDashboard() { coordinator.showDashboard() }
    @objc private func showRecordings() { coordinator.showRecordings() }
    @objc private func importVideo() { coordinator.importVideo() }
    @objc private func showHistory() { coordinator.showHistory() }
    @objc private func showSettings() { coordinator.showSettings() }
    @objc private func capture(_ sender: NSMenuItem) { coordinator.start(CaptureMode.allCases[sender.tag - 100]) }
    @objc private func repeatArea() { coordinator.start(.region, repeatSelection: true) }
    @objc private func unlockPins() { coordinator.unlockPins() }
    @objc private func delayedCapture(_ sender: NSMenuItem) { coordinator.start(.region, delay: sender.tag) }
    @objc private func stopRecording() { Task { await coordinator.recorder.stop() } }
    @objc private func pauseRecording() { Task { await coordinator.recorder.togglePause() } }
    @objc private func stopScrolling() {
        ScrollFileDialog.complete(for: coordinator.scrollCapture) { Task { await coordinator.scrollCapture.finish() } }
    }
    @objc private func saveScrolling() { coordinator.saveScrollCapture() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openSupport() { guard permissionGate?.allowEntry() != false else { return }; ShotloomSupportWindow.shared.show() }
    @objc private func openPrivacyPolicy() { guard permissionGate?.allowEntry() != false else { return }; NSWorkspace.shared.open(AppSupport.privacyURL) }
    @objc private func checkForUpdates() { guard permissionGate?.allowEntry() != false else { return }; coordinator.updates.checkForUpdates() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard permissionGate?.allowEntry() != false else { return true }
        // A normal reactivation must preserve an existing editor or menu.
        if flag || statusMenu?.popover.isShown == true { return true }
        showLaunchGuide(); return true
    }
    private func showLaunchGuide() {
        guard let statusItem, statusItem.button != nil else { return }
        statusMenu.close()
        launchGuide.show(relativeTo: statusItem) { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            if !self.statusMenu.popover.isShown { self.statusMenu.toggle(relativeTo: button) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { permissionGate?.applicationWillTerminate(); diagnosticPasteboard?.releaseGlobally(); launchGuide.dismiss(); AppPreferences.clearDiagnosticDomain() }
    func applicationDidBecomeActive(_ notification: Notification) { permissionGate?.applicationDidBecomeActive() }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let coordinator else { pendingOpenURLs.append(contentsOf: urls.prefix(max(0, 20 - pendingOpenURLs.count))); return }
        guard permissionGate?.allowEntry() != false else { pendingOpenURLs.append(contentsOf: urls.prefix(max(0, 20 - pendingOpenURLs.count))); return }
        for url in urls {
            if url.isFileURL, ["deskvideo", "desktutorial"].contains(url.pathExtension.lowercased()) { coordinator.openPortableProject(url); continue }
            guard let command = CaptureURLCommand(url) else { continue }
            switch command {
            case .capture(let mode, let delay, let repeatSelection): coordinator.start(mode, delay: delay, repeatSelection: repeatSelection)
            case .history: coordinator.showHistory()
            case .settings: coordinator.showSettings()
            case .workflow(let id): coordinator.showWorkflow(id: id)
            }
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        coordinator.refreshScreenAvailability()
        for (index, mode) in CaptureMode.allCases.enumerated() {
            menu.item(withTag: 100 + index)?.isHidden = !mode.isAvailable(screenCount: coordinator.screenCount)
        }
        for item in menu.items {
            if let submenu = item.submenu {
                for child in submenu.items { child.isEnabled = !coordinator.captureIsBusy }
            }
        }
        menu.item(withTag: 910)?.isEnabled = (coordinator.lastSelection != nil || coordinator.lastDesktopRegion != nil) && !coordinator.captureIsBusy
        for item in menu.items where (100..<(100 + CaptureMode.allCases.count)).contains(item.tag) || item.tag == 911 || item.tag == 917 {
            item.isEnabled = !coordinator.captureIsBusy
        }
        menu.item(withTag: 901)?.isHidden = coordinator.recorder.state == .idle
        menu.item(withTag: 902)?.isHidden = coordinator.recorder.state == .idle
        menu.item(withTag: 903)?.isHidden = !coordinator.scrollCapture.active
        menu.item(withTag: 904)?.isHidden = !coordinator.scrollCapture.active
        menu.item(withTag: 903)?.title = coordinator.scrollCapture.requiresStreamingExport ? L10n.text("完成长截图并导出分块 PNG…") : L10n.text("完成长截图并复制")
        menu.item(withTag: 904)?.title = coordinator.scrollCapture.requiresStreamingExport ? L10n.text("完成长截图并保存分页 PDF…") : L10n.text("完成长截图并保存文件…")
        for tag in [903, 904] { menu.item(withTag: tag)?.isEnabled = !coordinator.scrollCapture.finishing && !coordinator.scrollCapture.choosingFile && !coordinator.scrollCapture.processingSegment }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator != nil else { return .terminateNow }
        if coordinator.updates.isRelaunchRequested, let reason = coordinator.updateBlockReason {
            coordinator.flash(reason); return .terminateCancel
        }
        if coordinator.hasClipboardSaves {
            coordinator.flash(L10n.text("文本或PDF正在保存，请完成后退出。"))
            return .terminateCancel
        }
        if coordinator.hasImageHistorySaves {
            coordinator.flash(L10n.text("正在存入可编辑图片副本，请完成后退出。"))
            return .terminateCancel
        }
        if coordinator.hasImageFileExports {
            coordinator.flash(L10n.text("图片正在保存，请完成或取消保存后退出。"))
            return .terminateCancel
        }
        let editors = sender.windows.compactMap { ($0 as? VideoResultPanel)?.editSession }
        if editors.contains(where: { $0.busy }) {
            coordinator.flash(L10n.text("视频编辑器正在处理，请完成或取消当前操作后退出。"))
            return .terminateCancel
        }
        let unsaved = editors.filter { session in
            session.window?.makeFirstResponder(nil)
            if let state = session.capture?() { session.record(state) }
            return session.dirty
        }
        let imageEditors = sender.windows.compactMap { $0 as? ImageEditorWindow }
        if imageEditors.contains(where: { $0.preserving }) {
            coordinator.flash(L10n.text("正在存入可编辑图片副本，请完成后退出。"))
            return .terminateCancel
        }
        let unsavedImages = imageEditors.filter { $0.hasUnpreservedEdits }
        let unsavedText = sender.windows.compactMap { $0.delegate as? ClipboardEditor }.filter { $0.hasUnsavedChanges }
        if !unsaved.isEmpty || !unsavedImages.isEmpty || !unsavedText.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text("有 \(unsaved.count + unsavedImages.count + unsavedText.count) 个编辑窗口尚未保留修改")
            alert.informativeText = L10n.text("返回编辑器保留可编辑修改；直接退出会放弃这些修改，原始素材与已导出文件保留。")
            alert.addButton(withTitle: L10n.text("返回编辑"))
            alert.addButton(withTitle: L10n.text("放弃修改并退出"))
            if alert.runModal() != .alertSecondButtonReturn {
                if let window = unsaved.first?.window { window.makeKeyAndOrderFront(nil) }
                else if let window = unsavedImages.first { window.makeKeyAndOrderFront(nil) }
                else { unsavedText.first?.window.makeKeyAndOrderFront(nil) }
                return .terminateCancel
            }
        }
        if coordinator.deviceRecorder.state == .recording || coordinator.deviceRecorder.state == .paused {
            coordinator.deviceRecorder.onFinish = nil
            Task { await coordinator.deviceRecorder.stop(); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        if coordinator.deviceRecorder.state != .idle { return .terminateCancel }
        if coordinator.scrollCapture.finishing {
            coordinator.flash(L10n.text("长图正在完成写入，请稍后再退出。")); return .terminateCancel
        }
        if coordinator.recorder.state == .recording || coordinator.recorder.state == .paused {
            Task {
                coordinator.recorder.onFinish = nil; await coordinator.recorder.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        if coordinator.recorder.state != .idle {
            coordinator.flash(L10n.text("视频正在完成写入，请稍后再退出。")); return .terminateCancel
        }
        return .terminateNow
    }

    private func runCaptureDiagnostic() {
        Task { @MainActor in
            let engine = CaptureEngine()
            var result: [String: Any] = ["preflight": CGPreflightScreenCaptureAccess(), "bundle": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? ""]
            do {
                let content = try await engine.content()
                let snapshots = try await engine.snapshots(content: content)
                result["captureSucceeded"] = true; result["displays"] = snapshots.count
                result["pixels"] = snapshots.map { "\($0.image.width)x\($0.image.height)" }
                if CommandLine.arguments.contains("--capture-options-diagnostic") {
                    var options = CapturePreferences(); options.hideDesktop = true; options.windowBackdrop = .transparent; options.windowShadow = false
                    let clean = try await engine.snapshots(content: content, preferences: options)
                    result["hiddenDesktopPixels"] = clean.map { "\($0.image.width)x\($0.image.height)" }
                    if let window = content.windows.first(where: { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 300 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }) {
                        let image = try await engine.capture(window: window, preferences: options)
                        let scale = CGFloat(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)
                        let shadow = CapturePreferences.windowImage(image, backdrop: .transparent, shadow: true, scale: scale)!
                        try CaptureImageExport.png(image, to: URL(fileURLWithPath: "/tmp/deskcapture-window-transparent.png"))
                        try CaptureImageExport.png(shadow, to: URL(fileURLWithPath: "/tmp/deskcapture-window-shadow.png"))
                        result["windowPixels"] = "\(image.width)x\(image.height)"
                        result["shadowPixels"] = "\(shadow.width)x\(shadow.height)"
                    } else { throw CaptureError.message("No window available for diagnostic") }
                }
            } catch {
                result["captureSucceeded"] = false; result["error"] = error.localizedDescription
                result["errorDomain"] = (error as NSError).domain; result["errorCode"] = (error as NSError).code
            }
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try? data.write(to: URL(fileURLWithPath: "/tmp/deskcapture-diagnostic.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self)); NSApp.terminate(nil)
        }
    }

    private func runCameraRecordingSmokeTest() {
        let recorder = coordinator.deviceRecorder
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 440, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DeviceRecordingView(recorder: recorder))
        window.orderFrontRegardless()
        var saved: URL?
        recorder.onFinish = { saved = $0 }
        Task { @MainActor in
            var results: [[String: Any]] = []
            do {
                await recorder.refresh()
                guard let device = recorder.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { throw CaptureError.message(L10n.text("没有内置摄像头。")) }
                recorder.selectedID = device.uniqueID
                // Exercise preview removal while shutdown is queued, then reconnect
                // to the same camera for another recording, including pause/resume.
                for index in 0..<2 {
                    saved = nil
                    await recorder.start(diagnostic: true)
                    guard recorder.state == .recording else { throw CaptureError.message(recorder.message ?? L10n.text("摄像头启动失败。")) }
                    try await Task.sleep(for: .seconds(index == 0 ? 55 : 2))
                    if index == 1 {
                        await recorder.togglePause()
                        guard recorder.state == .paused else { throw CaptureError.message(recorder.message ?? L10n.text("暂停失败。")) }
                        await recorder.togglePause()
                        guard recorder.state == .recording else { throw CaptureError.message(recorder.message ?? L10n.text("继续失败。")) }
                        try await Task.sleep(for: .seconds(2))
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    await recorder.stop()
                    let stopSeconds = ProcessInfo.processInfo.systemUptime - start
                    guard let saved, recorder.state == .idle else { throw CaptureError.message(recorder.message ?? L10n.text("保存失败。")) }
                    // Yield to AppKit so preview teardown and the previous deadlock
                    // path actually run before considering the recording successful.
                    try await Task.sleep(for: .seconds(1))
                    let asset = AVURLAsset(url: saved)
                    let duration = try await asset.load(.duration).seconds
                    guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty, duration > (index == 0 ? 50 : 3) else { throw CaptureError.message(L10n.text("保存的视频缺少画面或时长。")) }
                    _ = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 1, preferredTimescale: 600))
                    results.append(["duration": duration, "stopSeconds": stopSeconds, "file": saved.path, "pauseResume": index == 1])
                }
                results.append(["success": true])
            } catch { results.append(["success": false, "error": error.localizedDescription]) }
            let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try? data.write(to: URL(fileURLWithPath: "/tmp/deskcapture-camera-diagnostic.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            window.close(); NSApp.terminate(nil)
        }
    }

    private func runStudioDiagnostic() {
        Task {
            guard let path = CommandLine.arguments.first(where: { $0.hasPrefix("--source=") })?.dropFirst(9) else { NSApp.terminate(nil); return }
            let source = URL(fileURLWithPath: String(path))
            var results: [[String: Any]] = []
            for mode in ["lens", "camera", "audio", "both"] {
                var options = RecordingEffectsOptions(); options.layout = .portrait
                options.camera.enabled = mode == "camera" || mode == "both"; options.camera.shape = .circle
                options.audio.cleanup = mode == "audio" || mode == "both"; options.audio.normalize = options.audio.cleanup
                options.lenses = [RecordingLens(start: 0.1, end: 1.5, x: 0.7, y: 0.6, zoom: 1.8)]
                let output = URL(fileURLWithPath: "/tmp/deskcapture-studio-\(mode).mp4")
                do {
                    try await RecordingEffectsExporter.export(source, to: output, options: options)
                    results.append(["mode": mode, "success": true])
                } catch { results.append(["mode": mode, "success": false, "details": String(describing: error as NSError)]) }
            }
            print(String(decoding: try! JSONSerialization.data(withJSONObject: results, options: .prettyPrinted), as: UTF8.self)); NSApp.terminate(nil)
        }
    }
    private func runRecordingSmokeTest() {
        let recorder = coordinator.recorder
        var diagnosticWindowID: UInt32?
        let previousMicrophone = recorder.microphone
        let previousCamera = recorder.cameraEnabled
        recorder.cameraEnabled = false
        let previousSystemAudio = recorder.systemAudio
        let previousSmoothCursor = recorder.smoothCursor
        let previousShortcuts = recorder.captureShortcuts
        recorder.microphone = false; recorder.systemAudio = true
        recorder.smoothCursor = false; recorder.captureShortcuts = false
        func report(_ values: [String: Any]) {
            recorder.microphone = previousMicrophone
            recorder.cameraEnabled = previousCamera
            recorder.systemAudio = previousSystemAudio
            recorder.smoothCursor = previousSmoothCursor; recorder.captureShortcuts = previousShortcuts
            var reportValues = values
            reportValues["captureTarget"] = diagnosticWindowID == nil ? "region" : "independent-window"
            if let diagnosticWindowID { reportValues["windowID"] = diagnosticWindowID }
            let data = try! JSONSerialization.data(withJSONObject: reportValues, options: [.prettyPrinted, .sortedKeys])
            try? data.write(to: URL(fileURLWithPath: "/tmp/deskcapture-recording-diagnostic.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self)); NSApp.terminate(nil)
        }
        recorder.onError = { error in report(["success": false, "error": error.localizedDescription, "details": String(describing: error as NSError)]) }
        recorder.onFinish = { url in
            fputs("Diagnostic: screen movie saved\n", stderr)
            Task {
                do {
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration).seconds
                    let video = try await asset.loadTracks(withMediaType: .video).count
                    let audio = try await asset.loadTracks(withMediaType: .audio).count
                    fputs("Diagnostic: metadata loaded\n", stderr)
                    let gif = URL(fileURLWithPath: "/tmp/deskcapture-recording-diagnostic.gif")
                    try await VideoGIFExporter.export(url, to: gif)
                    fputs("Diagnostic: GIF exported\n", stderr)
                    let trimmed = URL(fileURLWithPath: "/tmp/deskcapture-recording-trimmed.mp4")
                    try? FileManager.default.removeItem(at: trimmed)
                    try await VideoTrimmer.export(url, to: trimmed, start: 0.2, end: min(duration, 1.2))
                    fputs("Diagnostic: trim exported\n", stderr)
                    let trimAsset = AVURLAsset(url: trimmed)
                    let trimDuration = try await trimAsset.load(.duration).seconds
                    let trimVideo = try await trimAsset.loadTracks(withMediaType: .video).count
                    fputs("Diagnostic: trim metadata loaded\n", stderr)
                    let fixture = RecordingInteractions(smoothCursor: true, events: [
                        RecordedInteraction(time: 0, x: 0.2, y: 0.4, kind: .pointer),
                        RecordedInteraction(time: 0.7, x: 0.7, y: 0.6, kind: .pointer),
                        RecordedInteraction(time: 0.8, x: 0.7, y: 0.6, kind: .click),
                        RecordedInteraction(time: 1, x: 0.7, y: 0.6, kind: .shortcut, label: "⌘C")])
                    try JSONEncoder().encode(fixture).write(to: RecordingInteractions.url(for: url), options: .atomic)
                    var annotation = Annotation(tool: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.4)])
                    annotation.color = .systemRed; annotation.fill = .solid
                    let drawings = RecordingDrawingTimeline(frames: [RecordingDrawingFrame(time: 0.2, marks: [AnnotationArchive(annotation)]), RecordingDrawingFrame(time: 1.4, marks: [])])
                    try JSONEncoder().encode(drawings).write(to: RecordingDrawingTimeline.url(for: url), options: .atomic)
                    let effects = URL(fileURLWithPath: "/tmp/deskcapture-recording-effects.mp4")
                    try? FileManager.default.removeItem(at: effects)
                    fputs("Diagnostic: exporting effects\n", stderr)
                    try await RecordingEffectsExporter.export(url, to: effects, options: RecordingEffectsOptions())
                    fputs("Diagnostic: effects exported\n", stderr)
                    let effectAsset = AVURLAsset(url: effects)
                    let effectVideo = try await effectAsset.loadTracks(withMediaType: .video).count
                    let effectAudio = try await effectAsset.loadTracks(withMediaType: .audio).count
                    let effectDuration = try await effectAsset.load(.duration).seconds
                    let effectTrack = try await effectAsset.loadTracks(withMediaType: .video).first
                    let effectFrameRate = try await effectTrack?.load(.nominalFrameRate) ?? 0
                    let generator = AVAssetImageGenerator(asset: effectAsset)
                    _ = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                    let portrait = URL(fileURLWithPath: "/tmp/deskcapture-recording-caption-portrait.mp4")
                    try? FileManager.default.removeItem(at: portrait)
                    var cameraFixture = RecordingEffectsOptions(); cameraFixture.layout = .square
                    cameraFixture.style = .rose; cameraFixture.camera.enabled = false; cameraFixture.smartZoom = false
                    try await RecordingEffectsExporter.export(url, to: RecordingCamera.url(for: url), options: cameraFixture)
                    var captionOptions = RecordingEffectsOptions(); captionOptions.layout = .portrait
                    captionOptions.camera.shape = .circle; captionOptions.camera.width = 0.3
                    captionOptions.audio.cleanup = true; captionOptions.audio.normalize = true; captionOptions.audio.fade = 0.15
                    captionOptions.lenses = [RecordingLens(start: 0.1, end: 1.5, x: 0.7, y: 0.6, zoom: 1.8)]
                    captionOptions.captions = [CaptionSegment(start: 0, end: 0.7, text: L10n.text("现场编辑 · DeskCapture")),
                                               CaptionSegment(start: 0.7, end: 1.2, text: L10n.text("删除片段"), keep: false),
                                               CaptionSegment(start: 1.2, end: duration, text: L10n.text("字幕时间轴随删剪同步"))]
                    try await RecordingEffectsExporter.export(url, to: portrait, options: captionOptions)
                    let portraitAsset = AVURLAsset(url: portrait)
                    let portraitDuration = try await portraitAsset.load(.duration).seconds
                    let portraitTrack = try await portraitAsset.loadTracks(withMediaType: .video).first!
                    let portraitSize = try await portraitTrack.load(.naturalSize)
                    let portraitGenerator = AVAssetImageGenerator(asset: portraitAsset)
                    let preview = try await portraitGenerator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
                    try CaptureImageExport.png(preview, to: URL(fileURLWithPath: "/tmp/deskcapture-caption-portrait.png"))
                    report(["success": duration > 1 && video > 0 && trimDuration > 0.7 && trimDuration < 1.3 && trimVideo > 0 && effectVideo > 0 && abs(effectDuration - duration) < 0.15 && effectFrameRate >= 29 && abs(portraitDuration - (duration - 0.5)) < 0.15 && abs(portraitSize.width / portraitSize.height - 9.0 / 16.0) < 0.01,
                            "portraitDuration": portraitDuration, "portraitWidth": portraitSize.width, "portraitHeight": portraitSize.height,
                            "duration": duration, "videoTracks": video, "audioTracks": audio,
                            "trimDuration": trimDuration, "trimVideoTracks": trimVideo,
                            "effectVideoTracks": effectVideo, "effectAudioTracks": effectAudio,
                            "effectDuration": effectDuration, "effectFrameRate": effectFrameRate,
                            "file": url.path, "gif": gif.path, "trimmed": trimmed.path, "effects": effects.path])
                } catch { report(["success": false, "error": error.localizedDescription, "details": String(describing: error as NSError)]) }
            }
        }
        Task {
            do {
                guard let screen = NSScreen.main else { throw CaptureError.message("No screen") }
                let content = try await CaptureEngine().content()
                let target = CommandLine.arguments.contains("--window-recording-smoke-test") ? content.windows.first(where: { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 300 && $0.frame.height > 200 && $0.owningApplication != nil && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }) : nil
                if CommandLine.arguments.contains("--window-recording-smoke-test"), target == nil { throw CaptureError.message("No window available for window recording diagnostic") }
                diagnosticWindowID = target?.windowID
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let rect = target.map { CGRect(x: $0.frame.minX - screen.frame.minX, y: top - $0.frame.maxY - screen.frame.minY, width: $0.frame.width, height: $0.frame.height) } ?? CGRect(x: 40, y: 120, width: 480, height: 270)
                try await recorder.start(screen: screen, rect: rect, content: content, diagnostic: true, window: target)
                try await Task.sleep(for: .milliseconds(1200)); await recorder.togglePause()
                guard recorder.state == .paused else { throw CaptureError.message("Pause failed") }
                try await Task.sleep(for: .milliseconds(400)); await recorder.togglePause()
                guard recorder.state == .recording else { throw CaptureError.message("Resume failed") }
                try await Task.sleep(for: .milliseconds(1200)); await recorder.stop()
            } catch { report(["success": false, "error": error.localizedDescription, "details": String(describing: error as NSError)]) }
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
}
