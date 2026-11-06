import AppKit
import ScreenCaptureKit
import SwiftUI
import Combine

enum CaptureDestination: Equatable { case workflow(UUID), configureWorkflow
    case clipboard, file, pin, beautify, text, table, code, qr, scrolling, scrollingHorizontal, recording, recordingWindow, scrollingWindow }

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SelectionSession {
    private var panels: [CapturePanel] = []
    private var views: [SelectionView] = []
    private var escapeMonitor: Any?
    private let engine = CaptureEngine()
    var onComplete: ((CGImage, CaptureDestination, AnnotationDocument?) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onRegionAction: ((NSScreen, CGRect, CaptureDestination, SCWindow?, ScrollCaptureOrientation) -> Void)?
    var onSelection: ((NSScreen, CGRect) -> Void)?
    var onDesktopSelection: ((CGRect) -> Void)?
    var onWindowRecording: ((SCWindow, NSScreen) -> Void)?

    init(snapshots: [ScreenSnapshot], windows: [SCWindow], mode: CaptureMode, previewRect: CGRect? = nil,
         lastSelection: LastCaptureSelection? = nil, recorder: ScreenRecorder? = nil, recordWindow: Bool = false, lastDesktop: DesktopRegionMemory? = nil, inputOnly: Bool = false, colorPasteboard: NSPasteboard = .general, scrollingWindow: Bool = false, initialScrollDirection: ScrollDirection = .forward) {
        let zOrder = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let ranks = Dictionary(uniqueKeysWithValues: zOrder.enumerated().map { ($0.element, $0.offset) })
        let candidates = windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 40 &&
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.sorted { (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max) }
        let requestedCrossScreen = snapshots.count > 1 && [.region, .text].contains(mode)
        let combined = requestedCrossScreen ? DesktopCapture.combine(snapshots) : nil
        let crossScreen = combined != nil
        let sharedState = InlineCaptureState()
        for original in snapshots {
            let snapshot = combined ?? original
            let panel = CapturePanel(contentRect: original.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.title = L10n.text("\(mode.title) · 现场标注")
            panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(snapshot: snapshot, mode: mode, windows: candidates, recorder: recorder, recordWindow: recordWindow, sharedState: crossScreen ? sharedState : nil, inputOnly: inputOnly, colorPasteboard: colorPasteboard, scrollingWindow: scrollingWindow)
            view.scrollOrientation = initialScrollDirection == .reverse ? .up : .down
            view.onComplete = { [weak self, weak view] destination in
                guard let self, let view else { return }
                if inputOnly {
                    guard destination == .clipboard else { return }
                    do { for topology in snapshots.compactMap(\.topology) { try topology.requireUnchanged() } }
                    catch { self.onError?(error); return }
                }
                if [.recordingWindow, .recording, .scrolling, .scrollingHorizontal, .scrollingWindow].contains(destination) {
                    do { for topology in snapshots.compactMap(\.topology) { try topology.requireUnchanged() } }
                    catch { self.onError?(error); return }
                }
                if mode == .region, let rect = view.selection {
                    let world = rect.offsetBy(dx: snapshot.frame.minX, dy: snapshot.frame.minY)
                    if let screen = snapshots.map(\.screen).first(where: { $0.frame.contains(world) }) { self.onSelection?(screen, world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)) }
                    else { self.onDesktopSelection?(world) }
                }
                if destination == .scrollingWindow {
                    guard let target = view.selectedWindow else { return }
                    // The rectangle anchors the HUD. Its source is the exact
                    // window, including when it spans more than one display.
                    self.close()
                    self.onRegionAction?(snapshot.screen, view.selection ?? .zero, destination, target, view.scrollOrientation)
                    return
                }
                if destination == .recordingWindow {
                    let target: SCWindow?
                    if mode == .window { target = view.selectedWindow }
                    else if let rect = view.selection {
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        let point = CGPoint(x: snapshot.frame.minX + rect.midX, y: top - snapshot.frame.minY - rect.midY)
                        target = candidates.first { $0.frame.contains(point) }
                    } else { target = nil }
                    guard let target else { self.onError?(CaptureError.message(L10n.text("选区中没有可录制的窗口，请从窗口截图选择。"))); return }
                    self.close(); self.onWindowRecording?(target, snapshot.screen); return
                }
                if destination == .scrolling || destination == .scrollingHorizontal || destination == .recording {
                    if destination != .recording, !view.prepareScrollSelection() { return }
                    guard let rect = view.selection else { return }
                    let world = rect.offsetBy(dx: snapshot.frame.minX, dy: snapshot.frame.minY)
                    guard let screen = snapshots.map(\.screen).first(where: { $0.frame.contains(world) }) else { self.onError?(CaptureError.message(L10n.text("长图和录屏需在单块屏幕内选择；普通截图支持跨屏。"))); return }
                    self.close(); self.onRegionAction?(screen, world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), destination, destination == .recording ? nil : view.scrollTargetWindow,
                        destination == .scrollingHorizontal ? (view.scrollOrientation.direction == .reverse ? .left : .right) : view.scrollOrientation); return
                }
                guard let document = view.document else { NSSound.beep(); return }
                document.renderForDelivery { [weak self, weak view] image in
                    guard let self, let view, view.document === document, self.views.contains(where: { $0 === view }) else { return }
                    self.close(); self.onComplete?(image, destination, document)
                }
            }
            view.onActivate = { [weak self, weak view] in
                if !crossScreen { self?.views.filter { $0 !== view }.forEach { $0.clearSelection() } }
                else { self?.views.forEach { $0.setToolbarVisible($0 === view) } }
            }
            view.onWindowSelected = { [weak self, weak view] window in
                Task { @MainActor in
                    guard let self, let view else { return }
                    do {
                        let image: CGImage
                        if scrollingWindow { image = try await self.engine.scrollingWindow(window) }
                        else { image = try await self.engine.capture(window: window) }
                        guard self.views.contains(where: { $0 === view }), view.selectedWindow?.windowID == window.windowID else { return }
                        view.installWindowImage(image, backingScale: CGFloat(SCContentFilter(desktopIndependentWindow: window).pointPixelScale))
                    } catch {
                        guard self.views.contains(where: { $0 === view }), view.selectedWindow?.windowID == window.windowID else { return }
                        self.close(); self.onError?(error)
                    }
                }
            }
            view.onCancel = { [weak self] in self?.cancel() }
            if crossScreen {
                let container = NSView(frame: CGRect(origin: .zero, size: original.frame.size))
                view.setFrameOrigin(CGPoint(x: snapshot.frame.minX - original.frame.minX, y: snapshot.frame.minY - original.frame.minY))
                container.addSubview(view); panel.contentView = container
                view.onDesktopUpdate = { [weak self, weak view] rect, document, transient in
                    guard let self, let view else { return }
                    self.views.filter { $0 !== view }.forEach { $0.mirror(rect, document: document, transient: transient) }
                    if document != nil, !view.isGestureInProgress, let index = self.panels.firstIndex(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                        self.views.forEach { $0.setToolbarVisible($0 === self.views[index]) }
                        self.panels[index].makeKey(); self.panels[index].makeFirstResponder(self.views[index])
                    }
                }
            } else { panel.contentView = view }
            panel.acceptsMouseMovedEvents = true
            if let previewRect { view.setInitialSelectionForPreview(previewRect) }
            else if let saved = lastDesktop, saved.compatible(snapshots), combined != nil { view.setInitialSelectionForPreview(saved.rect.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)) }
            else if let rect = lastSelection?.selection(for: original.screen) { view.setInitialSelectionForPreview(rect.offsetBy(dx: original.screen.frame.minX - snapshot.frame.minX, dy: original.screen.frame.minY - snapshot.frame.minY)) }
            panels.append(panel); views.append(view)
        }
    }
    @discardableResult func confirmInputForDiagnostics() -> Bool {
        guard let view = views.first(where: { $0.document != nil }) else { return false }
        view.onComplete?(.clipboard); return true
    }
    @discardableResult func confirmScrollForDiagnostics() -> Bool {
        guard let view = views.first(where: { $0.selection != nil }) else { return false }
        view.onComplete?(.scrolling); return true
    }
    func show() {
        if escapeMonitor == nil {
            // Intercept before SwiftUI controls, field editors, or popovers consume Esc.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if self.handleEscape(event) || self.handleBeautifyShortcut(event) { return nil }
                return event
            }
        }
        panels.forEach { $0.orderFrontRegardless() }
        let target = panels.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panels.first
        target?.makeKey()
        if let document = views.first?.document, views.first?.snapshot.desktopFrame != nil { for view in views.dropFirst() { view.mirror(views.first?.selection, document: document, transient: nil) } }
        if let target, let index = panels.firstIndex(where: { $0 === target }) { target.makeFirstResponder(views[index]); views.forEach { $0.setToolbarVisible($0 === views[index]) } }
    }
    func displayForMeasurement() {
        panels.forEach { $0.displayIfNeeded() }
    }
    @discardableResult
    func handleEscape(_ event: NSEvent) -> Bool {
        guard !panels.isEmpty, event.type == .keyDown, event.keyCode == 53 else { return false }
        cancel()
        return true
    }
    private func handleBeautifyShortcut(_ event: NSEvent) -> Bool {
        guard !panels.isEmpty, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
              event.charactersIgnoringModifiers?.lowercased() == "b" else { return false }
        // Consume before the application's ⇧⌘B menu command can open an empty
        // workspace above a frozen-screen capture, including input-only sessions.
        let index = panels.firstIndex(where: { $0.isKeyWindow })
        let view = index.map { views[$0] } ?? views.first(where: { $0.document != nil })
        if let view, view.supportsBeautification { view.onComplete?(.beautify) }
        return true
    }
    func cancel() {
        guard !panels.isEmpty else { return }
        close(); onCancel?()
    }
    func close() {
        views.forEach { $0.document?.cancelPixelPreparation() }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll(); views.removeAll()
    }
    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }
}

final class InlineCaptureState: ObservableObject {
    @Published var scrollOrientation: ScrollCaptureOrientation = .down
    @Published var scrollSelectionMessage: String?
    @Published var scrollSelectionReady = false
    @Published var pickingColor = false
    @Published var liveColor: CaptureColorSample?
    @Published var pickedColor: CaptureColorSample?
    @Published var copiedColor: String?
    @Published var tool: AnnotationTool?
    @Published var lastShape: AnnotationTool = .arrow
    @Published var liftingContent = false
    @Published var detectedElements: [CGRect] = []
    @Published var elementMessage: String?
    @Published var selectingMark = false
    @Published var showSizeEditor = false
    @Published var expandsUpward = false
    @Published var pixelWidth = 0
    @Published var pixelHeight = 0
    @Published var aspectRatio: CaptureAspectRatio = .free
}

struct CaptureOutputDrag: ViewModifier {
    let enabled: Bool
    let document: AnnotationDocument
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.onDrag {
            return document.outputDragProvider()
        } } else { content }
    }
}

struct InlineCaptureToolbar: View {
    @ObservedObject var document: AnnotationDocument
    @ObservedObject var state: InlineCaptureState
    let mode: CaptureMode
    let complete: (CaptureDestination) -> Void
    let cancel: () -> Void
    let focus: () -> Void
    let resizeSelection: (Int, Int) -> Void
    let changeAspectRatio: (CaptureAspectRatio) -> Void
    var recorder: ScreenRecorder? = nil
    var recordWindow = false
    var scrollingWindow = false
    var inputOnly = false
    var colorPasteboard: NSPasteboard = .general
    var moveToolbar: (CGSize) -> Void = { _ in }
    @ObservedObject private var presets = AnnotationPresetStore.shared
    @ObservedObject private var toolbarPreferences = ToolbarPreferences.shared
    @ObservedObject private var workflows = WorkflowCatalog.shared
    private var isRecordingSelection: Bool { mode == .recording || recordWindow }
    @State private var showColorShelf = false
    @State private var showStyleShelf = false
    @State private var showRecordingOptions = false
    @State private var showRewrite = false
    @State private var showSensitive = false
    @ViewBuilder var body: some View {
        if inputOnly {
            HStack(spacing: 12) {
                if document.preparingPixels { ProgressView().controlSize(.small) }
                Text(mode == .window ? L10n.text("已选窗口") : L10n.text("已选区域")).font(.caption)
                Button(mode == .window ? L10n.text("采用窗口") : L10n.text("采用选区")) { complete(.clipboard) }.disabled(document.preparingPixels).keyboardShortcut(.defaultAction)
                Button(L10n.text("取消"), action: cancel).keyboardShortcut(.cancelAction)
            }.padding(10).background(GlassSurface()).clipShape(RoundedRectangle(cornerRadius: 10))
        } else if scrollingWindow { windowScrollSelectionBody }
        else if mode == .scrolling { scrollSelectionBody }
        else { standardBody }
    }
    private var windowScrollSelectionBody: some View {
        HStack(spacing: 10) {
            CaptureDragHandle(move: moveToolbar).frame(width: 14, height: 28)
            Image(systemName: "macwindow").foregroundStyle(Palette.ice)
            scrollOrientationPicker
            Spacer(minLength: 0)
            Button(L10n.text("取消"), action: cancel).buttonStyle(StudioButtonStyle(command: true))
            Button(L10n.text("开始窗口长图")) { complete(.scrollingWindow) }.buttonStyle(StudioButtonStyle(primary: true, command: true))
                .keyboardShortcut(.defaultAction)
        }.controlSize(.small).padding(.horizontal, 12).frame(height: 50)
            .foregroundStyle(Palette.white).background(OpticalPanel(radius: 14))
    }
    private var scrollSelectionBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                CaptureDragHandle(move: moveToolbar).frame(width: 14, height: 28)
                Image(systemName: "viewfinder").foregroundStyle(Palette.ice)
                sizeControl
                Spacer(minLength: 0)
                scrollOrientationPicker
                Button(L10n.text("取消"), action: cancel).buttonStyle(StudioButtonStyle(command: true))
                Button(L10n.text("开始长图")) { complete(.scrolling) }.buttonStyle(StudioButtonStyle(primary: true, command: true))
                    .disabled(!state.scrollSelectionReady).keyboardShortcut(.defaultAction)
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 50)
            if let message = state.scrollSelectionMessage {
                Divider().padding(.horizontal, 12)
                Text(message).font(.system(size: 12)).lineLimit(2)
                    .foregroundStyle(state.scrollSelectionReady ? Palette.muted : Color.orange)
                    .padding(.horizontal, 14).frame(height: 44, alignment: .leading)
            }
        }.foregroundStyle(Palette.white).background(OpticalPanel(radius: 14))
    }
    private var scrollOrientationPicker: some View {
        Picker(L10n.text("滚动方向"), selection: $state.scrollOrientation) {
            ForEach(ScrollCaptureOrientation.allCases) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }.labelsHidden().pickerStyle(.menu).frame(width: 92, alignment: .trailing)
            .help(L10n.text("捕获前选择滚动方向"))
    }
    private var standardBody: some View {
        VStack(spacing: 0) {
            if document.preparingPixels { HStack { ProgressView().controlSize(.small); Text(L10n.text("正在处理图像…")); Button(L10n.text("取消")) { document.cancelPixelPreparation() } }.font(.caption).padding(6) }
            if let error = document.pixelPreparationError { Text(error).font(.caption).foregroundStyle(.orange).padding(4) }
            if state.expandsUpward { accessoryControls }
            HStack(spacing: 2) {
                if isRecordingSelection { CaptureDragHandle(move: moveToolbar).frame(width: 14, height: 28) }
                toolButton(L10n.text("调整选区"), symbol: "viewfinder", selected: state.tool == nil && !state.selectingMark && !state.pickingColor) {
                    state.tool = nil; state.selectingMark = false; document.selectMark(at: CGPoint(x: -1, y: -1), tolerance: .zero); focus()
                }
                if isRecordingSelection {
                    sizeControl
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(toolbarPreferences.displayed) { item in
                                configurableControl(item)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                if isRecordingSelection, let recorder {
                    toolButton(L10n.text("录屏设置"), symbol: "slider.horizontal.3") { showRecordingOptions = true }
                        .popover(isPresented: $showRecordingOptions) {
                            RecordingConfigurationView(recorder: recorder).padding(14).frame(width: 350)
                        }
                }
                if !isRecordingSelection { Menu {
                    ForEach(toolbarPreferences.hidden) { item in
                        overflowControl(item)
                    }
                    Divider()

                    if mode == .window || mode == .recording { Button(mode == .window ? L10n.text("录制这个窗口") : L10n.text("录制选区所在窗口")) { complete(.recordingWindow) } }
                    Button(L10n.text("常用标注样式…")) { showStyleShelf = true }
                    Button(L10n.text("重做 ⇧⌘Z")) { document.redo(); focus() }.disabled(!document.canRedo)
                    Divider()
                    if document.selectedMark != nil {
                        Button(L10n.text("复制选中标注 ⌘D")) { document.duplicateSelectedOnCanvas(); focus() }
                        Button(L10n.text("置于顶层")) { document.reorderSelected(front: true); focus() }
                        Button(L10n.text("置于底层")) { document.reorderSelected(front: false); focus() }
                        Button(L10n.text("删除选中标注")) { document.deleteSelected(); focus() }
                        Divider()
                    }
                    Button(L10n.text("移动原图元素…")) {
                        state.tool = nil; state.selectingMark = false; state.pickingColor = false; state.liftingContent = true; state.elementMessage = L10n.text("正在识别元素，也可手动框选…"); focus()
                        Task {
                            do { state.detectedElements = try await AnnotationDocument.findElements(document.original); state.elementMessage = L10n.text("点击元素或框选内容，再拖动移动") }
                            catch { state.elementMessage = L10n.text("未能识别，可手动框选后移动") }
                        }
                    }
                    Button(L10n.text("叠加图片…")) { document.importOverlay { state.tool = nil; state.selectingMark = true; focus() } }
                    Button(L10n.text("导出前后对照 GIF…")) { document.exportComparison() }
                    Divider()
                    Button(L10n.text("滚动长截图")) { complete(.scrolling) }
                    Button(L10n.text("横向滚动长截图")) { complete(.scrollingHorizontal) }
                    Button(L10n.text("录制这块区域")) { complete(.recording) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 34) }
                    .menuStyle(.borderlessButton).fixedSize().help(L10n.text("样式、图片和其他捕获方式"))
                    .background(CaptureSizePopoverAnchor(isPresented: overflowSizeEditor, content: AnyView(sizeEditor)))
                }
                if !isRecordingSelection {
                    Button { complete(.beautify) } label: {
                        Label(L10n.text("美化"), systemImage: "sparkles").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 34)
                    }.buttonStyle(StudioButtonStyle(radius: 8, quiet: true, accentHover: true))
                        .help(L10n.text("美化当前截图 ⇧⌘B")).accessibilityLabel(L10n.text("美化当前截图"))
                        .disabled(document.preparingPixels || document.replacingOCR || document.arrangingMarks)
                }
                toolButton(L10n.text("取消 Esc"), symbol: "xmark") { cancel() }
                Button { complete(destination) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol)
                        Text(buttonTitle).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "return").font(.system(size: 10))
                    }.foregroundStyle(Palette.onAccent).padding(.horizontal, 12).frame(height: 34)
                        .background(Palette.ice, in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).help(isRecordingSelection ? L10n.text("开始录制；也可按 Enter 或双击选区") : mode == .scrolling ? L10n.text("开始长图捕获") : L10n.text("复制并结束；双击选区也可完成"))
                    .modifier(CaptureOutputDrag(enabled: !isRecordingSelection && mode != .scrolling, document: document))
            }.padding(.horizontal, 8).frame(height: 50)
            if !isRecordingSelection && mode != .text { workflowBar }
            if !state.expandsUpward { accessoryControls }
        }.background(OpticalPanel(radius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
            .task { await workflows.refresh() }
            .popover(isPresented: $showStyleShelf) {
                AnnotationStyleShelf(store: presets, document: document, tool: state.tool ?? document.selectedMark?.tool ?? .arrow) { style in
                    style.apply(to: document); state.tool = style.tool; state.selectingMark = false; state.pickingColor = false; showStyleShelf = false; focus()
                }
            }
            .popover(isPresented: $showColorShelf) { FavoriteColorShelf(store: presets, document: document) { showColorShelf = false; focus() } }
            .popover(isPresented: $showSensitive) {
                SensitiveReviewView(document: document) {
                    showSensitive = false; state.tool = nil; state.selectingMark = false; focus()
                }
            }
            .popover(isPresented: $showRewrite) {
                InlineOCRRewriteView(document: document) {
                    showRewrite = false; state.tool = nil; state.selectingMark = true; focus()
                }
            }
    }
    @ViewBuilder private var accessoryControls: some View {
        if let message = state.scrollSelectionMessage {
            Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                .padding(.horizontal, 12).frame(height: 44)
        }
        if state.liftingContent {
            HStack { Text(state.elementMessage ?? L10n.text("框选原图内容，再拖动移动")).font(.system(size: 11)).foregroundStyle(Palette.ice); Spacer(); Button(L10n.text("取消")) { state.liftingContent = false; state.detectedElements = []; focus() } }.padding(.horizontal, 12).frame(height: 48)
        } else if state.pickingColor {
            Rectangle().fill(Palette.chrome.opacity(0.14)).frame(height: 1).padding(.horizontal, 11)
            HStack(spacing: 10) {
                if let sample = state.pickedColor ?? state.liveColor {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: sample.color)).frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.chrome.opacity(0.3)))
                    Text(sample.hex).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(sample.rgb).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                    Button(L10n.text("复制 HEX")) { copyColor(sample.hex) }
                    Button(L10n.text("复制 RGB")) { copyColor(sample.rgb) }
                    Button { presets.addColor(sample.hex) } label: { Image(systemName: "star") }.help(L10n.text("收藏这个颜色"))
                } else { Text(L10n.text("移动指针查看颜色，点击取色")).font(.system(size: 11)) }
                Spacer(minLength: 0)
                Text(state.copiedColor == nil ? L10n.text("sRGB · 点击取色") : L10n.text("已复制")).font(.system(size: 10)).foregroundStyle(Palette.ice)
                Button(L10n.text("完成取色")) { state.pickingColor = false; focus() }
            }.buttonStyle(.plain).padding(.horizontal, 11).frame(height: 48)
        } else if let tool = state.tool ?? (state.selectingMark ? document.selectedMark?.tool : nil) {
            Rectangle().fill(Palette.chrome.opacity(0.14)).frame(height: 1).padding(.horizontal, 11)
            ScrollView(.horizontal) {
                propertyBar(for: tool).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
            }.scrollIndicators(.hidden).frame(height: propertyHeight(for: tool))
        }
    }
    private var workflowBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(workflows.recipes) { recipe in
                    Button { complete(.workflow(recipe.id)) } label: { Label(recipe.name, systemImage: recipe.toolbarSymbol) }
                }
                if let error = workflows.error { Text(error) }
                Divider()
                Button(L10n.text("新建或管理流程…")) { complete(.configureWorkflow) }
            } label: { Label(L10n.text("流程"), systemImage: "point.3.connected.trianglepath.dotted") }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.text("运行已保存的流程，或配置自己的流程"))
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(workflows.pinned) { recipe in
                        StudioIconButton(title: L10n.text("运行流程：\(recipe.name)"), symbol: recipe.toolbarSymbol) {
                            complete(.workflow(recipe.id))
                        }
                    }
                }
            }.scrollIndicators(.hidden)
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 38)
            .overlay(alignment: .top) { Divider().padding(.horizontal, 10) }
            .disabled(document.preparingPixels || document.replacingOCR || document.arrangingMarks)
    }
    @ViewBuilder private func overflowControl(_ item: CaptureToolbarItem) -> some View {
        if item == .recognition {
            recognitionControl(inMenu: true)
        } else {
            Button(item.title) {
                switch item {
                case .select: state.tool = nil; state.selectingMark = true; state.pickingColor = false; state.liftingContent = false; focus()
                case .color: state.pickingColor.toggle(); state.tool = nil; state.selectingMark = false; state.liftingContent = false; focus()
                case .size: state.showSizeEditor = true
                case .shape: state.tool = state.lastShape; state.selectingMark = false; state.pickingColor = false; state.liftingContent = false; focus()
                case .undo: document.undo(); focus()
                case .pin: complete(.pin)
                case .save: complete(.file)
                default:
                    if let tool = item.tool { state.tool = tool; state.selectingMark = false; state.pickingColor = false; state.liftingContent = false; focus() }
                }
            }.disabled((item == .undo && !document.canUndo) || (item == .size && (!document.marks.isEmpty || mode == .window)))
        }
    }
    @ViewBuilder private func configurableControl(_ item: CaptureToolbarItem) -> some View {
        switch item {
        case .select:
            toolButton(item.title, symbol: "cursorarrow.rays", selected: state.selectingMark) {
                state.tool = nil; state.selectingMark = true; state.pickingColor = false; state.liftingContent = false; focus()
            }
        case .color:
            toolButton(L10n.text("取色 P · 点击复制 HEX · ⇧Tab 复制 RGB"), symbol: "eyedropper", selected: state.pickingColor) {
                state.pickingColor.toggle(); state.tool = nil; state.selectingMark = false; state.liftingContent = false; focus()
            }
        case .size: sizeControl
        case .shape:
            toolButton(L10n.text("形状"), symbol: state.tool?.isShape == true ? state.tool!.symbol : "square.on.circle", selected: state.tool?.isShape == true) {
                state.tool = state.lastShape; state.selectingMark = false; state.pickingColor = false; state.liftingContent = false; focus()
            }
        case .undo:
            toolButton(L10n.text("撤销 ⌘Z"), symbol: "arrow.uturn.backward") { document.undo(); focus() }.disabled(!document.canUndo)
        case .recognition: recognitionControl()
        case .pin: toolButton(item.title, symbol: "pin") { complete(.pin) }
        case .save: toolButton(L10n.text("保存 PNG ⌘S"), symbol: "square.and.arrow.down") { complete(.file) }
        default:
            if let tool = item.tool {
                toolButton(tool.title, symbol: tool.symbol, selected: state.tool == tool) {
                    state.tool = tool; state.selectingMark = false; state.pickingColor = false; state.liftingContent = false; focus()
                }
            }
        }
    }
    private var sizeControl: some View {
        toolButton(L10n.text("尺寸与比例 · \(state.aspectRatio.title)"), symbol: "aspectratio", selected: state.aspectRatio != .free) { state.showSizeEditor = true }
            .disabled(!document.marks.isEmpty || mode == .window)
            .background(CaptureSizePopoverAnchor(isPresented: $state.showSizeEditor, content: AnyView(sizeEditor)))
    }
    private var overflowSizeEditor: Binding<Bool> {
        Binding(get: { state.showSizeEditor && toolbarPreferences.hidden.contains(.size) },
                set: { state.showSizeEditor = $0 })
    }
    private var sizeEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("尺寸与比例")).font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(CaptureAspectRatio.allCases) { ratio in
                    Button { changeAspectRatio(ratio) } label: {
                        HStack(spacing: 4) {
                            Text(ratio.title)
                            Spacer(minLength: 0)
                            if state.aspectRatio == ratio { Image(systemName: "checkmark") }
                        }.font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(state.aspectRatio == ratio ? Palette.ice.opacity(0.2) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            Text(L10n.text("精确尺寸 · 像素")).font(.system(size: 11, weight: .medium))
            HStack {
                InspectorField(title: L10n.text("宽度")) { TextField(L10n.text("像素"), value: dimensionBinding(width: true), format: .number).accessibilityLabel(L10n.text("选区宽度（像素）")) }
                InspectorField(title: L10n.text("高度")) { TextField(L10n.text("像素"), value: dimensionBinding(width: false), format: .number).accessibilityLabel(L10n.text("选区高度（像素）")) }
            }
            Button(L10n.text("应用尺寸")) {
                resizeSelection(state.pixelWidth, state.pixelHeight)
                state.showSizeEditor = false; focus()
            }.disabled(state.pixelWidth < 3 || state.pixelHeight < 3)
        }.textFieldStyle(.roundedBorder).controlSize(.small).padding(16).frame(width: 280)
    }
    private func recognitionControl(inMenu: Bool = false) -> some View {
        Menu {
            Button(L10n.text("检查并遮盖敏感信息…")) { showSensitive = true }
            Button(L10n.text("现场改写原图文字…")) { showRewrite = true }
            Divider()
            Button(L10n.text("复制文字")) { complete(.text) }
            if #available(macOS 26, *) { Button(L10n.text("提取表格 TSV")) { complete(.table) } }
            else { Button(L10n.text("提取表格 TSV · 需macOS 26")) {}.disabled(true).help(L10n.text("当前系统可使用复制文字并校对表格内容。")) }
            Button(L10n.text("提取代码（保留缩进）")) { complete(.code) }
            Button(L10n.text("识别二维码 / 条码")) { complete(.qr) }
        } label: {
            if inMenu { Label(L10n.text("文字与内容识别"), systemImage: "text.viewfinder") }
            else { Image(systemName: "text.viewfinder").frame(width: 28, height: 34) }
        }.menuStyle(.borderlessButton).fixedSize().help(L10n.text("文字与内容识别"))
    }
    private func dimensionBinding(width: Bool) -> Binding<Int> {
        Binding(get: { width ? state.pixelWidth : state.pixelHeight }, set: { value in
            if width { state.pixelWidth = value } else { state.pixelHeight = value }
            if value >= 3, state.aspectRatio.units != nil {
                let size = state.aspectRatio.pixelSize(width: CGFloat(state.pixelWidth), height: CGFloat(state.pixelHeight),
                                                      maximum: CGSize(width: CGFloat(Int.max / 2), height: CGFloat(Int.max / 2)), drivenByWidth: width)
                // Leave the edited field intact until applying; update its counterpart immediately.
                if width { state.pixelHeight = Int(size.height) } else { state.pixelWidth = Int(size.width) }
            }
        })
    }
    private func copyColor(_ value: String) {
        colorPasteboard.clearContents(); colorPasteboard.setString(value, forType: .string)
        state.copiedColor = value; focus()
    }
    static func propertyHeight(for tool: AnnotationTool?) -> CGFloat {
        guard let tool else { return 0 }
        return tool == .icon || tool.isShape || tool == .text || tool == .replace ? 78 : 48
    }
    private func propertyHeight(for tool: AnnotationTool) -> CGFloat { Self.propertyHeight(for: tool) }
    private var divider: some View { Divider().frame(height: 22).padding(.horizontal, 3) }
    @ViewBuilder private func propertyBar(for tool: AnnotationTool) -> some View {
        if tool == .icon {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text(L10n.text("矢量图标")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted).fixedSize()
                    ForEach(VectorIcon.allCases) { icon in
                        propertyButton(icon.title, symbol: icon.symbol, selected: document.icon == icon) { document.icon = icon; focus() }
                    }
                    Spacer(minLength: 2)
                    Text(L10n.text("拖动自由缩放")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
                }
                HStack(spacing: 5) {
                    colorControls
                    divider
                    Text(L10n.text("单击尺寸")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
                    Slider(value: $document.iconSize, in: 24...180).frame(width: 94)
                    Text("\(Int(document.iconSize))").font(.system(size: 10, design: .monospaced)).frame(width: 24)
                    Spacer(minLength: 0)
                }
            }
        } else if tool == .curvedArrow {
            VStack(spacing: 3) {
                HStack(spacing: 5) { shapeControls; divider; Text(L10n.text("弯曲")).font(.system(size: 10)); Slider(value: $document.curvature, in: -0.8...0.8).frame(width: 130); Spacer(minLength: 0) }
                HStack(spacing: 5) { colorControls; divider; lineWidthControls; Spacer(minLength: 0) }
            }
        } else if tool == .text || tool == .replace {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Text(L10n.text("样式")).font(.system(size: 10))
                    Picker(L10n.text("样式"), selection: $document.textStyle) { ForEach(AnnotationTextStyle.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    Menu(L10n.text("字体")) {
                        Button(L10n.text("系统字体")) { document.fontName = "" }
                        ForEach(["PingFangSC-Regular", "PingFangSC-Semibold", "HelveticaNeue", "HelveticaNeue-Bold", "Menlo-Regular", "Georgia"], id: \.self) { name in Button(name) { document.fontName = name } }
                    }.font(.system(size: 10))
                    Text(L10n.text("字号")).font(.system(size: 10)); Slider(value: $document.fontSize, in: 8...96).frame(width: 85)
                }
                HStack(spacing: 5) {
                    colorControls
                    if document.selectedMark != nil { TextField(L10n.text("文字"), text: $document.selectedText).frame(width: 165) }
                    Spacer(minLength: 0)
                }
            }
        } else if tool.isClosedShape {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    shapeControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    colorControls
                    divider
                    ForEach(AnnotationFill.allCases) { fill in
                        propertyButton(fill.title, symbol: fill.symbol, selected: document.fill == fill) { document.fill = fill; focus() }
                    }
                    divider
                    lineWidthControls
                    Spacer(minLength: 0)
                }
            }
        } else if tool.isShape {
            VStack(spacing: 3) {
                HStack(spacing: 5) { shapeControls; divider; lineWidthControls; Spacer(minLength: 0) }
                HStack(spacing: 5) { colorControls; Spacer(minLength: 0) }
            }
        } else {
            HStack(spacing: 6) {
                if tool == .magnify {
                    colorControls
                    divider
                    Text(L10n.text("放大倍率")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
                    Slider(value: $document.mosaicStrength, in: 1.2...5).frame(width: 100)
                    Text(String(format: "%.1f×", document.mosaicStrength)).font(.system(size: 10, design: .monospaced)).frame(width: 35)
                } else if tool == .mosaic {
                    Text(L10n.text("马赛克")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted).fixedSize()
                    ForEach(MosaicStyle.allCases) { style in
                        Button { document.mosaicStyle = style; focus() } label: {
                            Label(style.title, systemImage: style.symbol).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).frame(height: 28)
                                .foregroundStyle(document.mosaicStyle == style ? Palette.ice : Palette.white)
                                .background(document.mosaicStyle == style ? Palette.ice.opacity(0.16) : Palette.chrome.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).help(style.title)
                    }
                    divider
                    Text(L10n.text("强度")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
                    Slider(value: $document.mosaicStrength, in: 1...5, step: 1).frame(width: 84)
                    Text("\(Int(document.mosaicStrength))").font(.system(size: 10, design: .monospaced)).frame(width: 12)
                } else if tool == .redact {
                    Image(systemName: "lock.shield.fill").foregroundStyle(Palette.ice)
                    Text(L10n.text("导出时以纯黑像素覆盖；原图历史仍保留")).font(.system(size: 11)).foregroundStyle(Palette.white).fixedSize()
                } else if tool == .erase {
                    Image(systemName: "eraser").foregroundStyle(Palette.ice)
                    Picker(L10n.text("修复"), selection: $document.repairMode) { ForEach(RepairMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(width: 190)
                    Text(document.repairMode == .clone ? L10n.text("⌥点击干净区域取样，再框选修复") : L10n.text("框选移除；纹理模式寻找相近背景")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else if tool == .image {
                    Text(L10n.text("叠层透明度")).font(.system(size: 10)); Slider(value: $document.opacity, in: 0...1).frame(width: 140)
                    Text(L10n.text("宽度")).font(.system(size: 10))
                    Slider(value: Binding(get: { document.overlayPixelWidth }, set: { document.resizeSelectedImage(toWidth: $0) }),
                           in: 1...CGFloat(document.original.width)).frame(width: 160)
                    Text(L10n.text("拖动图片移动，拖动角点缩放")).font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else {
                    colorControls
                    divider
                    if tool == .text || tool == .step {
                        Text(L10n.text("字号")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
                        Slider(value: $document.fontSize, in: 14...64).frame(width: 76)
                        Text("\(Int(document.fontSize))").font(.system(size: 10, design: .monospaced)).frame(width: 20)
                    } else { lineWidthControls }
                }
                Spacer(minLength: 0)
            }
        }
    }
    private var shapeControls: some View {
        Group {
            Text(L10n.text("形状")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted).fixedSize()
                ForEach(AnnotationTool.shapes) { shape in
                    propertyButton(shape.title, symbol: shape.symbol, selected: state.tool == shape || (state.selectingMark && document.selectedMark?.tool == shape)) {
                        if state.selectingMark { document.changeSelectedShape(to: shape) }
                        else { state.lastShape = shape; state.tool = shape }
                        focus()
                    }
                }
        }
    }
    private var colorControls: some View {
        Group {
            Text(L10n.text("颜色")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted).fixedSize()
            ForEach(AnnotationColor.allCases) { preset in colorButton(preset) }
            CompactColorWell(color: Binding(get: { document.customColor ?? document.color.color },
                                            set: { document.customColor = $0 }))
                .frame(width: 24, height: 24).clipped().help(L10n.text("自定义颜色"))
            Button { showColorShelf = true } label: { Image(systemName: "star.circle").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help(L10n.text("收藏色板"))
            Button { showStyleShelf = true } label: { Image(systemName: "square.stack").frame(width: 24, height: 24) }
                .buttonStyle(.plain).help(L10n.text("常用标注样式"))

        }
    }
    private var lineWidthControls: some View {
        Group {
            Text(L10n.text("粗细")).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize()
            Slider(value: $document.lineWidth, in: 2...20).frame(width: 76)
            Text("\(Int(document.lineWidth))").font(.system(size: 10, design: .monospaced)).frame(width: 20)
        }
    }
    private func propertyButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            StudioSymbol(name: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Palette.ice : Palette.white).frame(width: 29, height: 28)
                .background(selected ? Palette.ice.opacity(0.16) : Palette.chrome.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func colorButton(_ preset: AnnotationColor) -> some View {
        let selected = document.customColor == nil && document.color == preset
        return Button { document.selectColor(preset); focus() } label: {
            Circle().fill(Color(nsColor: preset.color)).frame(width: 15, height: 15)
                .padding(3).overlay(Circle().strokeBorder(selected ? Palette.ice : Palette.chrome.opacity(0.20), lineWidth: selected ? 1.7 : 0.7))
        }.buttonStyle(.plain).help(preset.title).accessibilityLabel(preset.title)
    }
    private var destination: CaptureDestination {
        if scrollingWindow { return .scrollingWindow }
        if recordWindow { return .recordingWindow }
        switch mode { case .text: return .text; case .scrolling: return .scrolling; case .recording: return .recording; default: return .clipboard }
    }
    private var buttonTitle: String {
        if recordWindow { return L10n.text("开始录制") }
        switch mode { case .text: return L10n.text("复制文字"); case .scrolling: return L10n.text("开始长图"); case .recording: return L10n.text("开始录制"); default: return L10n.text("复制") }
    }
    private func toolButton(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            if symbol != "aspectratio" { state.showSizeEditor = false }
            if symbol != "eyedropper" { state.pickingColor = false; state.liftingContent = false }
            action()
        } label: {
            StudioSymbol(name: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Palette.ice : Palette.white).frame(width: 30, height: 34)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [OpticalPalette.cyan.opacity(0.26), OpticalPalette.violet.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.ice.opacity(0.5), lineWidth: 0.8))
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

final class SelectionView: NSView {
    let snapshot: ScreenSnapshot
    private let background: NSImage
    let mode: CaptureMode
    private let windows: [SCWindow]
    private let recorder: ScreenRecorder?
    private let recordWindow: Bool
    private let scrollingWindow: Bool
    private let inputOnly: Bool
    private let colorPasteboard: NSPasteboard
    private let state: InlineCaptureState
    private var tracking: NSTrackingArea?
    private var pointer = CGPoint.zero
    var isGestureInProgress: Bool { dragStart != nil || currentMark != nil || movingMark }
    private var dragStart: CGPoint?
    private var adjustingRegion = false
    private var originalRect: CGRect?
    private var moving = false
    private var movingMark = false
    private var imageResizeCorner: Int?
    private var markDragOriginal: [Annotation]?
    private var resizeCorner: Int?
    private var currentMark: Annotation?
    private var lockedWindow = false
    private var toolbar: NSHostingView<InlineCaptureToolbar>?
    private var toolbarOrigin: CGPoint?
    private var toolbarUpdateScheduled = false
    private var subscriptions: Set<AnyCancellable> = []
    private var documentSubscription: AnyCancellable?
    private var textEditor: TextAnnotationEditor?
    private(set) var selection: CGRect?
    private(set) var document: AnnotationDocument?
    private var hoverWindow: SCWindow?
    private(set) var scrollTargetWindow: SCWindow?
    var selectedWindow: SCWindow? { hoverWindow }
    var scrollOrientation: ScrollCaptureOrientation {
        get { state.scrollOrientation }
        set { state.scrollOrientation = newValue }
    }
    var onDesktopUpdate: ((CGRect?, AnnotationDocument?, Annotation?) -> Void)?
    var onComplete: ((CaptureDestination) -> Void)?
    var onCancel: (() -> Void)?
    var onActivate: (() -> Void)?
    var onWindowSelected: ((SCWindow) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    private var defaultDestination: CaptureDestination {
        if scrollingWindow { return .scrollingWindow }
        if recordWindow { return .recordingWindow }
        switch mode { case .text: return .text; case .scrolling: return .scrolling; case .recording: return .recording; default: return .clipboard }
    }
    var supportsBeautification: Bool {
        !inputOnly && !scrollingWindow && !recordWindow && mode != .recording && mode != .scrolling
            && document?.preparingPixels == false && document?.replacingOCR == false && document?.arrangingMarks == false
    }

    init(snapshot: ScreenSnapshot, mode: CaptureMode, windows: [SCWindow], recorder: ScreenRecorder? = nil, recordWindow: Bool = false, sharedState: InlineCaptureState? = nil, inputOnly: Bool = false, colorPasteboard: NSPasteboard = .general, scrollingWindow: Bool = false) {
        state = sharedState ?? InlineCaptureState()
        self.snapshot = snapshot; self.mode = mode; self.windows = windows; self.recorder = recorder; self.recordWindow = recordWindow; self.inputOnly = inputOnly; self.colorPasteboard = colorPasteboard; self.scrollingWindow = scrollingWindow
        self.background = NSImage(cgImage: snapshot.image, size: snapshot.frame.size)
        super.init(frame: CGRect(origin: .zero, size: snapshot.frame.size))
        state.objectWillChange.sink { [weak self] in
            self?.scheduleToolbarUpdate()
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let rect = selection, document != nil, state.tool == nil, !state.pickingColor { addCursorRect(rect.intersection(bounds), cursor: .openHand) }
        if let toolbar { addCursorRect(toolbar.frame, cursor: .arrow) }
    }
    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toolbar?.frame.contains(point) == true { NSCursor.arrow.set() }
        else if state.selectingMark, let rect = selection, document?.imageResizeHandle(at: point, in: rect) != nil { NSCursor.crosshair.set() }
        else if selection?.contains(point) == true, document != nil, state.tool == nil, !state.pickingColor { NSCursor.openHand.set() }
        else { NSCursor.crosshair.set() }
    }
    func setToolbarVisible(_ visible: Bool) { toolbar?.isHidden = !visible; if visible { positionToolbar() } }
    func mirror(_ rect: CGRect?, document source: AnnotationDocument?, transient: Annotation?) {
        selection = rect; currentMark = transient
        if let source, document !== source { installDocument(source.original, shared: source) }
        else if source == nil { document = nil; toolbar?.removeFromSuperview(); toolbar = nil }
        needsDisplay = true
    }
    func clearSelection() {
        textEditor?.commit(); textEditor = nil
        selection = nil; document = nil; currentMark = nil; lockedWindow = false; toolbarOrigin = nil
        documentSubscription = nil; toolbar?.removeFromSuperview(); toolbar = nil; needsDisplay = true
        onDesktopUpdate?(nil, nil, nil)
        scrollTargetWindow = nil; state.scrollSelectionMessage = nil; state.scrollSelectionReady = false
    }
    // Used only by the standalone development fixture, on a generated background.
    func setInitialSelectionForPreview(_ rect: CGRect) {
        selection = rect.intersection(bounds); installRegionImage(); needsDisplay = true
        if mode == .scrolling { prepareScrollSelection() }
    }
    private func windowRect(_ window: SCWindow) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: window.frame.minX - snapshot.frame.minX, y: top - window.frame.maxY - snapshot.frame.minY,
                      width: window.frame.width, height: window.frame.height)
    }
    /// An adjusted rectangle stays on screen for explicit confirmation. Other
    /// screenshot modes can also enter long capture through their action menu.
    @discardableResult func prepareScrollSelection() -> Bool {
        guard let selected = selection else { return false }
        let candidates = windows.map {
            ScrollSelectionResolver.Window(id: $0.windowID,
                title: $0.owningApplication?.applicationName ?? L10n.text("所选窗口"), frame: windowRect($0).intersection(bounds))
        }
        guard let resolved = ScrollSelectionResolver.resolve(selected, windows: candidates) else {
            scrollTargetWindow = nil; state.scrollSelectionReady = false
            state.scrollSelectionMessage = L10n.text("未选到可滚动页面。请在网页或文档里拖出至少40 × 40的区域。")
            needsDisplay = true; return false
        }
        scrollTargetWindow = windows.first { $0.windowID == resolved.window.id }
        state.scrollSelectionReady = true
        if resolved.adjusted {
            guard mode == .scrolling else {
                state.scrollSelectionMessage = L10n.text("长图会跟随一个页面滚动。请把选区缩到“\(resolved.window.title)”的可见页面内，再开始。")
                updateToolbarFrame(); needsDisplay = true; return false
            }
            selection = resolved.rect
            installRegionImage()
            state.scrollSelectionMessage = L10n.text("已调整到“\(resolved.window.title)”的可见区域，确认高亮范围后开始。")
        } else {
            if state.scrollSelectionMessage?.hasPrefix(L10n.text("已调整到")) != true {
                state.scrollSelectionMessage = L10n.text("捕获“\(resolved.window.title)”中的高亮区域")
            }
        }
        needsDisplay = true; updateToolbarFrame()
        return !resolved.adjusted
    }
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        if toolbar?.frame.contains(pointer) != true {
            let sample = colorUnderPointer
            if state.pickingColor && state.liveColor != sample { state.liveColor = sample }
            if let copied = state.copiedColor, copied != sample?.hex && copied != sample?.rgb { state.copiedColor = nil }
        }
        if mode == .window, !lockedWindow {
            let global = NSEvent.mouseLocation
            let point = CGPoint(x: global.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - global.y)
            hoverWindow = windows.first { $0.frame.contains(point) }
            selection = hoverWindow.map { windowRect($0) }
        }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard document?.preparingPixels != true, document?.replacingOCR != true, document?.arrangingMarks != true else { return }
        document?.presentationWindow = window
        window?.makeKey(); window?.makeFirstResponder(self); onActivate?()
        document?.commitPendingText = { [weak self] in self?.textEditor?.commit() }
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        if state.pickingColor {
            if let sample = colorUnderPointer { state.pickedColor = sample; copyPointerColor(rgb: false) }
            return
        }
        if state.liftingContent, let rect = selection, rect.contains(point), let document {
            let p = normalized(point, rect: rect)
            if let element = state.detectedElements.filter({ $0.contains(p) }).min(by: { $0.width * $0.height < $1.width * $1.height }) {
                document.liftContentOnCanvas(from: element.origin, to: CGPoint(x: element.maxX, y: element.maxY)); state.liftingContent = false; state.selectingMark = true; return
            }
            currentMark = document.makeMark(tool: .erase, points: [p, p]); needsDisplay = true; return
        }
        if event.clickCount == 2, selection?.contains(point) == true, document != nil { onComplete?(defaultDestination); return }
        if mode == .window, !lockedWindow {
            mouseMoved(with: event)
            guard let window = hoverWindow else { return }
            lockedWindow = true; onWindowSelected?(window); needsDisplay = true; return
        }
        guard !lockedWindow || document != nil else { return }
        if let rect = selection, state.selectingMark, let document,
           !event.modifierFlags.contains(.shift), let corner = document.imageResizeHandle(at: point, in: rect) {
            imageResizeCorner = corner; dragStart = point; movingMark = true
            markDragOriginal = document.marks; needsDisplay = true; return
        }
        if let rect = selection, state.selectingMark, let document, rect.contains(point) {
            document.selectMark(at: normalized(point, rect: rect),
                                tolerance: CGPoint(x: 8 / rect.width, y: 8 / rect.height), additive: event.modifierFlags.contains(.shift))
            dragStart = point; movingMark = document.selectedMark != nil
            markDragOriginal = movingMark ? document.marks : nil
            needsDisplay = true; return
        }
        if let rect = selection, state.tool == .erase, event.modifierFlags.contains(.option), rect.contains(point) {
            document?.repairMode = .clone; document?.repairAnchor = normalized(point, rect: rect); needsDisplay = true; return
        }
        if let rect = selection, let tool = state.tool, document != nil, rect.contains(point) {
            let p = normalized(point, rect: rect)
            if tool == .step { document?.addOnCanvas(document!.makeMark(tool: tool, points: [p])); needsDisplay = true; return }
            if tool == .text, let document {
                textEditor?.commit()
                textEditor = TextAnnotationEditor(in: self, at: point, fontSize: document.fontSize * rect.width / CGFloat(document.original.width), color: document.color.color) { [weak self, weak document] text in
                    guard let self else { return }
                    if !text.isEmpty { document?.addOnCanvas(document!.makeMark(tool: .text, points: [p], text: text)) }
                    self.textEditor = nil; self.needsDisplay = true
                }
                return
            }
            currentMark = document?.makeMark(tool: tool, points: [p, p]); needsDisplay = true; return
        }
        if mode == .window { return }
        dragStart = point; originalRect = selection; adjustingRegion = true
        resizeCorner = selection.flatMap { corner(at: point, in: $0) }
        moving = resizeCorner == nil && selection?.contains(point) == true && document != nil
        if !moving, resizeCorner == nil {
            clearSelection()
            // A fresh region starts in selection mode; old annotation modes belong to the discarded image.
            state.tool = nil; state.selectingMark = false; state.liftingContent = false
            state.detectedElements = []; state.elementMessage = nil; state.showSizeEditor = false
        }
        toolbar?.isHidden = true; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        defer { onDesktopUpdate?(selection, document, currentMark) }
        pointer = convert(event.locationInWindow, from: nil)
        if state.pickingColor { state.liveColor = colorUnderPointer; needsDisplay = true; return }
        if movingMark, let start = dragStart, let original = markDragOriginal, let rect = selection {
            let delta = CGPoint(x: (pointer.x - start.x) / rect.width, y: (pointer.y - start.y) / rect.height)
            if let corner = imageResizeCorner {
                document?.resizeSelectedImage(from: original, corner: corner, by: delta)
            } else { document?.moveSelected(from: original, by: delta, snapTolerance: CGSize(width: 6 / rect.width, height: 6 / rect.height)) }
            needsDisplay = true; return
        }
        if var mark = currentMark, let rect = selection {
            let p = normalized(pointer, rect: rect)
            if mark.tool == .pen { mark.points.append(p) }
            else if mark.tool == .icon, let document { mark.points[1] = document.iconEnd(from: mark.points[0], toward: p) }
            else { mark.points[1] = p }
            currentMark = mark; needsDisplay = true; return
        }
        guard adjustingRegion, let start = dragStart else { return }
        if moving, var rect = originalRect {
            rect.origin.x = min(max(0, rect.origin.x + pointer.x - start.x), bounds.width - rect.width)
            rect.origin.y = min(max(0, rect.origin.y + pointer.y - start.y), bounds.height - rect.height); selection = rect
        } else if let index = resizeCorner, let rect = originalRect {
            selection = CaptureGeometry.rect(from: corners(rect)[(index + 2) % 4], to: pointer, in: bounds,
                                             aspectRatio: state.aspectRatio, pixelScale: selectionPixelScale)
        } else {
            selection = CaptureGeometry.rect(from: start, to: pointer, in: bounds,
                                             aspectRatio: state.aspectRatio, pixelScale: selectionPixelScale)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { onDesktopUpdate?(selection, document, nil) }
        if state.pickingColor { return }
        if movingMark, let original = markDragOriginal { document?.commitMoveOnCanvas(from: original) }
        if let mark = currentMark, state.liftingContent, let a = mark.points.first, let b = mark.points.last {
            document?.liftContentOnCanvas(from: a, to: b); currentMark = nil; state.liftingContent = false; state.selectingMark = true
        } else if let mark = currentMark {
            let completed = document?.finishIcon(mark) ?? mark
            if let first = completed.points.first, let last = completed.points.last,
               hypot(last.x - first.x, last.y - first.y) > 0.001 || completed.points.count > 2 { document?.addOnCanvas(completed) }
            currentMark = nil
        } else if adjustingRegion {
            if selection != originalRect || document == nil { installRegionImage() }
            if mode == .scrolling { state.scrollSelectionMessage = nil; prepareScrollSelection() }
            toolbar?.isHidden = false; positionToolbar()
        }
        dragStart = nil; adjustingRegion = false; originalRect = nil; moving = false; movingMark = false; markDragOriginal = nil; imageResizeCorner = nil; resizeCorner = nil; needsDisplay = true
    }
    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    private func corner(at point: CGPoint, in rect: CGRect) -> Int? { corners(rect).firstIndex { hypot($0.x - point.x, $0.y - point.y) <= 10 } }
    private func normalized(_ point: CGPoint, rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func installRegionImage() {
        guard let rect = selection, rect.width >= 3, rect.height >= 3 else { clearSelection(); return }
        let pixelRect = CaptureGeometry.pixelRect(rect, viewSize: bounds.size, imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        guard let image = snapshot.image.cropping(to: pixelRect) else { return }
        state.pixelWidth = image.width; state.pixelHeight = image.height
        installDocument(image)
    }
    private var selectionPixelScale: CGSize {
        CGSize(width: CGFloat(snapshot.image.width) / bounds.width, height: CGFloat(snapshot.image.height) / bounds.height)
    }
    func changeAspectRatio(_ ratio: CaptureAspectRatio) {
        guard mode != .window, document?.marks.isEmpty == true, let rect = selection else { return }
        state.aspectRatio = ratio
        guard ratio.units != nil else { needsDisplay = true; return }
        let scale = selectionPixelScale
        let currentWidth = rect.width * scale.width, currentHeight = rect.height * scale.height
        let value = ratio.units!
        // Preserve the approximate area and center when changing orientation.
        let width = sqrt(currentWidth * currentHeight * value.width / value.height)
        let size = ratio.pixelSize(width: width, height: width * value.height / value.width,
                                  maximum: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        applySelectionSize(size, centered: true)
    }
    func resizeSelection(toPixelWidth width: Int, height: Int) {
        guard mode != .window, document?.marks.isEmpty == true, selection != nil,
              width >= 3, height >= 3, width <= snapshot.image.width, height <= snapshot.image.height else { return }
        let size = state.aspectRatio.pixelSize(width: CGFloat(width), height: CGFloat(height),
                                              maximum: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        applySelectionSize(size, centered: false)
    }
    private func applySelectionSize(_ size: CGSize, centered: Bool) {
        guard var rect = selection, size.width >= 3, size.height >= 3 else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY), scale = selectionPixelScale
        rect.size = CGSize(width: size.width / scale.width, height: size.height / scale.height)
        if centered { rect.origin = CGPoint(x: center.x - rect.width / 2, y: center.y - rect.height / 2) }
        rect.origin.x = min(max(bounds.minX, rect.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(bounds.minY, rect.minY), bounds.maxY - rect.height)
        selection = rect
        installRegionImage(); needsDisplay = true; onDesktopUpdate?(selection, document, nil)
        if mode == .scrolling { state.scrollSelectionMessage = nil; prepareScrollSelection() }
    }
    func installWindowImage(_ image: CGImage, backingScale: CGFloat? = nil) {
        let scale = backingScale ?? snapshot.screen.backingScaleFactor
        if let selected = selection {
            let padding = max(0, (CGFloat(image.width) / scale - selected.width) / 2)
            selection = selected.insetBy(dx: -padding, dy: -padding)
        }
        installDocument(image); document?.backingScale = scale; needsDisplay = true
    }
    private func installDocument(_ image: CGImage, shared: AnnotationDocument? = nil) {
        if let document, document !== shared { document.cancelPixelPreparation() }
        let doc = shared ?? AnnotationDocument(image: image); doc.backingScale = snapshot.scale; doc.presentationWindow = window; document = doc
        if shared == nil { doc.commitPendingText = { [weak self] in self?.textEditor?.commit() } }
        documentSubscription = doc.objectWillChange.sink { [weak self] in
            self?.scheduleToolbarUpdate()
        }
        let root = InlineCaptureToolbar(document: doc, state: state, mode: mode,
                                        complete: { [weak self] in self?.onComplete?($0) }, cancel: { [weak self] in self?.onCancel?() },
                                        focus: { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) },
                                        resizeSelection: { [weak self] width, height in self?.resizeSelection(toPixelWidth: width, height: height) },
                                        changeAspectRatio: { [weak self] ratio in self?.changeAspectRatio(ratio) }, recorder: recorder, recordWindow: recordWindow, scrollingWindow: scrollingWindow, inputOnly: inputOnly, colorPasteboard: colorPasteboard,
                                        moveToolbar: { [weak self] delta in
                                            guard let self, let toolbar = self.toolbar else { return }
                                            self.toolbarOrigin = CGPoint(x: toolbar.frame.minX + delta.width, y: toolbar.frame.minY + delta.height)
                                            self.positionToolbar()
                                        })
        if let toolbar {
            toolbar.rootView = root
            updateToolbarFrame()
        } else {
            let view = NSHostingView(rootView: root)
            // SelectionView owns geometry. SwiftUI intrinsic minimum-size changes
            // must not resize the fullscreen overlay or fight our toolbar frame.
            view.sizingOptions = []
            view.frame = CGRect(x: 0, y: 0, width: min(bounds.width - 20, toolbarWidth), height: toolbarHeight)
            addSubview(view); toolbar = view
        }
        positionToolbar(); window?.invalidateCursorRects(for: self)
    }
    private var toolbarWidth: CGFloat { scrollingWindow ? 420 : mode == .scrolling ? 460 : mode == .recording || recordWindow ? 360 : 660 }
    private func scheduleToolbarUpdate() {
        guard !toolbarUpdateScheduled else { return }
        toolbarUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toolbarUpdateScheduled = false
            self.needsDisplay = true
            self.updateToolbarFrame()
            self.window?.invalidateCursorRects(for: self)
        }
    }
    private func updateToolbarFrame() { positionToolbar() }
    private var toolbarHeight: CGFloat {
        if scrollingWindow { return 50 }
        if mode == .scrolling { return state.scrollSelectionMessage == nil ? 50 : 95 }
        let workflowHeight: CGFloat = mode != .recording && !recordWindow && mode != .text && !inputOnly ? 38 : 0
        let activeTool = state.tool ?? (state.selectingMark ? document?.selectedMark?.tool : nil)
        let propertyHeight: CGFloat = state.liftingContent ? 48 : state.pickingColor ? 49 :
            activeTool == nil ? 0 : 1 + InlineCaptureToolbar.propertyHeight(for: activeTool)
        return 50 + workflowHeight + (state.scrollSelectionMessage == nil ? 0 : 44) + propertyHeight
    }
    private func positionToolbar() {
        guard let toolbar, let rect = selection else { return }
        var viewport = visibleRect.isEmpty ? bounds : visibleRect
        if let screen = window?.screen {
            let usable = screen.visibleFrame.offsetBy(dx: -snapshot.frame.minX, dy: -snapshot.frame.minY)
            let intersection = viewport.intersection(usable)
            if !intersection.isNull && !intersection.isEmpty { viewport = intersection }
        }
        let size = CGSize(width: max(1, min(viewport.width - 20, toolbarWidth)), height: toolbarHeight)
        let visible = rect.intersection(viewport)
        let x = min(max(viewport.minX + 10, (visible.isNull ? viewport.maxX : visible.maxX) - size.width), viewport.maxX - size.width - 10)
        let annotationControls = !inputOnly && !scrollingWindow && mode != .scrolling && mode != .recording && !recordWindow
        // Pick a side using the largest normal parameter row. Switching tools
        // then keeps both the side and the primary button row in place.
        let workflowHeight: CGFloat = mode != .text ? 38 : 0
        let reservedHeight = annotationControls ? max(size.height, 50 + workflowHeight + 79 + (state.scrollSelectionMessage == nil ? 0 : 44)) : size.height
        let below = (visible.isNull ? viewport.minY : visible.minY) - reservedHeight - 12
        let upward = annotationControls && below < viewport.minY + 12
        if state.expandsUpward != upward { state.expandsUpward = upward }
        let y = below >= viewport.minY + 12 ? below : (visible.isNull ? viewport.maxY : visible.maxY) + 12
        let reserved = CapturePanelGeometry.clamp(CGRect(x: x, y: max(viewport.minY + 12, y), width: size.width, height: reservedHeight), to: viewport, margin: 10)
        let origin = toolbarOrigin ?? CGPoint(x: reserved.minX, y: upward ? reserved.minY : reserved.maxY - size.height)
        let fitted = CapturePanelGeometry.clamp(CGRect(origin: origin, size: size), to: viewport, margin: 10)
        // One frame assignment, and only when geometry actually changed.
        if toolbar.frame != fitted { toolbar.frame = fitted }
        if toolbarOrigin != nil { toolbarOrigin = fitted.origin }
    }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if inputOnly {
            if event.keyCode == 53 { onCancel?(); return }
            let confirm = event.keyCode == 36 || event.keyCode == 76 ||
                (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "c")
            if confirm { if document != nil { onComplete?(.clipboard) }; return }
            // Selection inputs must not expose the ordinary color-copy shortcuts
            // (Tab/P) or annotation delivery commands to the system pasteboard.
            guard [UInt16(123), 124, 125, 126].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }
        }
        if (mode == .recording || mode == .scrolling || recordWindow || scrollingWindow), ![UInt16(53), 36, 76, 123, 124, 125, 126].contains(event.keyCode) { return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                if state.pickingColor { copyPointerColor(rgb: event.modifierFlags.contains(.shift)) }
                else if document != nil { onComplete?(defaultDestination) }
                return
            case "s": if document != nil { onComplete?(.file) }; return
            case "a": state.tool = nil; state.selectingMark = true; document?.selectAllMarks(); needsDisplay = true; return
            case "d": document?.duplicateSelectedOnCanvas(); needsDisplay = true; return
            case "z": if event.modifierFlags.contains(.shift) { document?.redo() } else { document?.undo() }; needsDisplay = true; return
            default: break
            }
        }
        if event.charactersIgnoringModifiers?.lowercased() == "p", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            state.pickingColor.toggle(); state.tool = nil; state.selectingMark = false; needsDisplay = true; return
        }
        switch event.keyCode {
        case 48: copyPointerColor(rgb: event.modifierFlags.contains(.shift))
        case 53: cancelOperation(nil)
        case 51, 117: if state.selectingMark { document?.deleteSelected(); needsDisplay = true }
        case 36, 76: if document != nil { onComplete?(defaultDestination) } else { NSSound.beep() }
        case 123, 124, 125, 126:
            if state.selectingMark {
                let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                document?.nudgeOnCanvas(x: event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0,
                                       y: event.keyCode == 125 ? -amount : event.keyCode == 126 ? amount : 0)
                needsDisplay = true; return
            }
            guard document?.marks.isEmpty != false, mode != .window, var rect = selection else { return }
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            rect.origin.x = min(max(0, rect.origin.x + (event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0)), bounds.width - rect.width)
            rect.origin.y = min(max(0, rect.origin.y + (event.keyCode == 125 ? -amount : event.keyCode == 126 ? amount : 0)), bounds.height - rect.height)
            selection = rect; installRegionImage(); needsDisplay = true
            if mode == .scrolling { state.scrollSelectionMessage = nil; prepareScrollSelection() }
        default: super.keyDown(with: event)
        }
    }
    private func copyPointerColor(rgb: Bool) {
        guard let sample = colorUnderPointer else { return }
        let value = rgb ? sample.rgb : sample.hex
        colorPasteboard.clearContents(); colorPasteboard.setString(value, forType: .string)
        if state.pickingColor { state.pickedColor = sample }
        state.copiedColor = value; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        background.draw(in: bounds)
        NSColor(calibratedRed: 0.015, green: 0.04, blue: 0.09, alpha: 0.48).setFill(); bounds.fill()
        if let rect = selection, !rect.isEmpty {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
            if let document, dragStart == nil || state.selectingMark {
                NSImage(cgImage: document.original, size: rect.size).draw(in: rect)
                if let context = NSGraphicsContext.current?.cgContext {
                    AnnotationDocument.draw(document.marks + (currentMark.map { [$0] } ?? []), in: context, rect: rect, pixelWidth: CGFloat(document.original.width), source: document.original)
                }
                if let selected = document.selectionBounds(in: rect) {
                    NSColor(calibratedRed: 0.3, green: 0.91, blue: 0.97, alpha: 1).setStroke()
                    let focus = NSBezierPath(roundedRect: selected, xRadius: 4, yRadius: 4)
                    focus.lineWidth = 1.4; focus.setLineDash([4, 3], count: 2, phase: 0); focus.stroke()
                }
                document.drawImageResizeHandles(in: rect)
            } else { background.draw(in: bounds) }
            NSGraphicsContext.restoreGraphicsState()
            NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.95, alpha: 1).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5)); outline.lineWidth = 1; outline.stroke(); drawCorners(rect)
            if state.liftingContent {
                NSColor.systemTeal.withAlphaComponent(0.6).setStroke()
                for element in state.detectedElements {
                    NSBezierPath(rect: CGRect(x: rect.minX + element.minX * rect.width, y: rect.minY + element.minY * rect.height, width: element.width * rect.width, height: element.height * rect.height)).stroke()
                }
            }
            let pixels = CaptureGeometry.pixelRect(rect, viewSize: bounds.size, imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
            let width = dragStart == nil ? (document?.original.width ?? Int(pixels.width)) : Int(pixels.width)
            let height = dragStart == nil ? (document?.original.height ?? Int(pixels.height)) : Int(pixels.height)
            let ratioLabel = state.aspectRatio.units == nil ? "" : L10n.text(" · \(Int(state.aspectRatio.units!.width)):\(Int(state.aspectRatio.units!.height))")
            let label = lockedWindow && document == nil ? L10n.text("正在捕获窗口…") : "\(width) × \(height) px\(ratioLabel)"
            drawPill(label, at: CGPoint(x: min(max(12, rect.minX), bounds.width - 180), y: min(bounds.height - 45, max(12, rect.maxY + 10))))
        } else {
            NSColor.white.withAlphaComponent(0.22).setStroke(); let cross = NSBezierPath(); cross.lineWidth = 0.5
            cross.move(to: CGPoint(x: pointer.x, y: 0)); cross.line(to: CGPoint(x: pointer.x, y: bounds.height))
            cross.move(to: CGPoint(x: 0, y: pointer.y)); cross.line(to: CGPoint(x: bounds.width, y: pointer.y)); cross.stroke()
        }
        if document == nil {
            let text: String
            if scrollingWindow { text = L10n.text("点击选择窗口 · Enter 开始自动滚动长图 · Esc 取消") }
            else if recordWindow { text = L10n.text("点击选择窗口 · Enter 开始录制 · Esc 取消") }
            else { switch mode {
                case .recording: text = L10n.text("框选录制范围 · Enter 开始录制 · Esc 取消")
                case .scrolling: text = L10n.text("框选网页或文档 · 确认高亮范围后按 Enter · Esc 取消")
                case .text: text = L10n.text("框选文字 · Enter 识别复制 · Esc 取消")
                case .window: text = L10n.text("点击选择窗口 · Tab 取色 · Esc 取消")
                default: text = L10n.text("拖动框选 · 松手后标注 · 双击复制 · Tab 取色 · Esc 取消")
            } }
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            drawPill(text, at: CGPoint(x: visibleRect.midX - (size.width + 26) / 2, y: visibleRect.minY + 28))
        }
        if window?.frame.contains(NSEvent.mouseLocation) == true && toolbar?.frame.contains(pointer) != true && textEditor == nil {
            if document == nil || state.pickingColor { drawMagnifier() }
            else if mode != .scrolling && !scrollingWindow { drawColorInfo(at: CGPoint(x: pointer.x + 18, y: pointer.y + 18)) }
        }
    }
    private func drawMagnifier() {
        guard bounds.contains(pointer), pointer != .zero else { return }
        let sourceRect = CaptureGeometry.pixelRect(CGRect(x: pointer.x - 10, y: pointer.y - 10, width: 20, height: 20),
                                                   viewSize: bounds.size,
                                                   imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        guard let crop = snapshot.image.cropping(to: sourceRect) else { return }
        let side: CGFloat = 112
        let viewport = visibleRect
        let x = min(max(viewport.minX + 8, pointer.x + 18), viewport.maxX - side - 8)
        let y = min(max(viewport.minY + 8, pointer.y + 18), viewport.maxY - side - 8)
        let lens = CGRect(x: x, y: y, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: lens, xRadius: 9, yRadius: 9).addClip()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: crop, size: lens.size).draw(in: lens)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.96, alpha: 1).setStroke()
        let frame = NSBezierPath(roundedRect: lens, xRadius: 9, yRadius: 9); frame.lineWidth = 2; frame.stroke()
        let cross = NSBezierPath(); cross.lineWidth = 1
        cross.move(to: CGPoint(x: lens.midX - 7, y: lens.midY)); cross.line(to: CGPoint(x: lens.midX + 7, y: lens.midY))
        cross.move(to: CGPoint(x: lens.midX, y: lens.midY - 7)); cross.line(to: CGPoint(x: lens.midX, y: lens.midY + 7)); cross.stroke()
        drawColorInfo(at: CGPoint(x: x, y: lens.minY - 64))
    }
    private func drawColorInfo(at point: CGPoint) {
        if mode == .recording || mode == .scrolling || recordWindow || scrollingWindow { return }
        guard bounds.contains(pointer), let sample = colorUnderPointer else { return }
        let width: CGFloat = 224, height: CGFloat = 58
        let viewport = visibleRect
        let rect = CGRect(x: min(max(viewport.minX + 8, point.x), max(viewport.minX + 8, viewport.maxX - width - 8)),
                          y: min(max(viewport.minY + 8, point.y), max(viewport.minY + 8, viewport.maxY - height - 8)), width: width, height: height)
        if toolbar?.frame.intersects(rect) == true { return }
        NSColor(calibratedRed: 0.025, green: 0.08, blue: 0.14, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.2).setStroke(); NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).stroke()
        sample.color.setFill(); NSBezierPath(roundedRect: CGRect(x: rect.minX + 10, y: rect.minY + 15, width: 28, height: 28), xRadius: 5, yRadius: 5).fill()
        let title = state.copiedColor == nil ? L10n.text("\(sample.hex)  Tab 复制") : L10n.text("已复制 \(state.copiedColor!)")
        // Use the normal UI font for mixed Chinese/Latin copy. The monospaced
        // system font went through CoreText ApplyFont and raised an Objective-C
        // exception on the reported system; Swift do/catch cannot contain it.
        (title as NSString).draw(at: CGPoint(x: rect.minX + 48, y: rect.minY + 33), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        (L10n.text("\(sample.rgb) · sRGB") as NSString).draw(at: CGPoint(x: rect.minX + 48, y: rect.minY + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
    }
    private var colorUnderPointer: CaptureColorSample? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(pointer) else { return nil }
        return CapturePixelColor.sample(snapshot.image, at: CGPoint(x: pointer.x / bounds.width * CGFloat(snapshot.image.width),
            y: min(CGFloat(snapshot.image.height - 1), (bounds.height - pointer.y) / bounds.height * CGFloat(snapshot.image.height))))
    }
    private func drawPill(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs), r = CGRect(origin: point, size: CGSize(width: size.width + 26, height: 30))
        NSColor(calibratedRed: 0.025, green: 0.08, blue: 0.14, alpha: 0.88).setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.18).setStroke(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).stroke()
        (text as NSString).draw(at: CGPoint(x: point.x + 13, y: point.y + 8), withAttributes: attrs)
    }
    private func drawCorners(_ r: CGRect) {
        NSColor.white.setStroke(); let length = min(12, min(r.width, r.height) / 3), path = NSBezierPath(); path.lineWidth = 2
        for (x, y, dx, dy) in [(r.minX, r.minY, CGFloat(1), CGFloat(1)), (r.maxX, r.minY, -1, 1), (r.minX, r.maxY, 1, -1), (r.maxX, r.maxY, -1, -1)] {
            path.move(to: CGPoint(x: x, y: y + dy * length)); path.line(to: CGPoint(x: x, y: y)); path.line(to: CGPoint(x: x + dx * length, y: y))
        }
        path.stroke()
        if mode != .window, document != nil, state.tool == nil {
            NSColor.white.setFill(); for p in corners(r) { NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill() }
        }
    }
}
