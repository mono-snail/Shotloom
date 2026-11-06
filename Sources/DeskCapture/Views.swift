import AppKit
import SwiftUI

struct GlassMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct GlassSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            if !reduceTransparency { GlassMaterial() }
            Palette.ink.opacity(reduceTransparency ? 1 : (scheme == .dark ? 0.94 : 0.96))
        }
    }
}

struct CompactColorWell: NSViewRepresentable {
    @Binding var color: NSColor
    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        well.colorWellStyle = .minimal
        well.target = context.coordinator; well.action = #selector(Coordinator.changed(_:))
        well.toolTip = L10n.text("自定义颜色")
        return well
    }
    func updateNSView(_ view: NSColorWell, context: Context) {
        context.coordinator.color = $color
        if view.color != color { view.color = color }
    }
    final class Coordinator: NSObject {
        var color: Binding<NSColor>
        init(color: Binding<NSColor>) { self.color = color }
        @objc func changed(_ sender: NSColorWell) { color.wrappedValue = sender.color }
    }
}

struct ViewfinderMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Palette.selection)
            CaptureFrameShape().stroke(Palette.ice, style: StrokeStyle(lineWidth: max(1.3, size * 0.052), lineCap: .round))
                .padding(size * 0.22)
            HStack(spacing: size * 0.14) {
                Circle().fill(Palette.ice); Circle().fill(Palette.ice)
            }.frame(width: size * 0.29, height: size * 0.075).offset(y: -size * 0.035)
            CaptureSmile().stroke(Palette.ice, style: StrokeStyle(lineWidth: max(1, size * 0.035), lineCap: .round))
                .frame(width: size * 0.18, height: size * 0.09).offset(y: size * 0.14)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var primary = false
    var compact = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, compact ? 11 : 13).padding(.vertical, compact ? 7 : 10)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(StudioButtonStyle(primary: primary))
    }
}

struct NoticeView: View {
    let text: String
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Palette.ice)
            Text(text).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
            if let dismiss {
                Spacer(minLength: 6)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(.plain).help(L10n.text("关闭提示"))
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ink.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.ice.opacity(0.28)))
            .foregroundStyle(Palette.white)
    }
}

typealias DashboardView = CompactLauncherView

struct ViewfinderShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); let l: CGFloat = 24
        for (x, y, dx, dy) in [(rect.minX, rect.minY, CGFloat(1), CGFloat(1)), (rect.maxX, rect.minY, -1, 1), (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1)] {
            p.move(to: CGPoint(x: x, y: y + dy * l)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        return p
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "常规", shortcuts = "快捷键", toolbar = "工具栏按钮", recording = "录制", storage = "存储与隐私"
    var id: Self { self }
    var symbol: String {
        switch self { case .general: "slider.horizontal.3"; case .shortcuts: "keyboard"; case .toolbar: "square.grid.2x2"; case .recording: "record.circle"; case .storage: "externaldrive" }
    }
    var detail: String {
        switch self {
        case .general: L10n.text("让每一次捕获更贴合你的习惯。")
        case .shortcuts: L10n.text("设置全局热键，查看界面内快捷键。")
        case .toolbar: L10n.text("选择常用按钮，调整显示顺序。")
        case .recording: L10n.text("调整声音、摄像头与演示效果。")
        case .storage: L10n.text("素材和文字保存在你的 Mac 上。")
        }
    }
}


struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var document: AnnotationDocument
    @Binding var zoom: CGFloat?
    @Binding var displayedZoom: CGFloat
    func makeNSView(context: Context) -> EditorCanvasScrollView {
        let scroll = EditorCanvasScrollView()
        scroll.documentView = AnnotationCanvas(document: document)
        return scroll
    }
    func updateNSView(_ scroll: EditorCanvasScrollView, context: Context) {
        scroll.onZoom = { zoom = $0 }
        scroll.onDisplayedZoom = { displayedZoom = $0 }
        scroll.update(zoom: zoom)
    }
}

struct HistoryAnnotationControls: View {
    @ObservedObject var document: AnnotationDocument
    @State private var showingContentBoundary = false
    @State private var showingTutorialPresets = false
    @State private var showingImageComparison = false
    private var activeTool: AnnotationTool { document.selectingMark ? (document.selectedMark?.tool ?? document.tool) : document.tool }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                Menu(document.selectedMarkIDs.count > 1 ? L10n.text("已选 \(document.selectedMarkIDs.count) 项") : L10n.text("标注操作")) {
                    Button(L10n.text("全选 ⌘A")) { document.selectingMark = true; document.selectAllMarks() }
                    Button(L10n.text("复制选中 ⌘D")) { document.duplicateSelectedOnCanvas() }.disabled(document.selectedMarkIDs.isEmpty)
                    Button(L10n.text("置于顶层")) { document.reorderSelected(front: true) }.disabled(document.selectedMarkIDs.isEmpty)
                    Button(L10n.text("置于底层")) { document.reorderSelected(front: false) }.disabled(document.selectedMarkIDs.isEmpty)
                    Button(L10n.text("删除选中")) { document.deleteSelected() }.disabled(document.selectedMarkIDs.isEmpty)
                    Divider()
                    Toggle(L10n.text("拖动吸附"), isOn: $document.snapsAnnotations)
                    Button(L10n.text("内容边界与尺寸…")) { showingContentBoundary = true }
                    Button(L10n.text("品牌与教程预设…")) { showingTutorialPresets = true }
                    Button(L10n.text("图片对照与差异…")) { showingImageComparison = true }
                    ForEach(AnnotationArrangement.allCases) { operation in
                        Button(operation.title) { Task { await document.arrangeSelected(operation) } }
                            .disabled(document.selectedMarkIDs.count < 2 || document.arrangingMarks)
                    }
                }.fixedSize().help(L10n.text("Shift 点选多个标注；方向键微调，Shift 加速"))
                    .popover(isPresented: $showingContentBoundary) { ContentBoundaryView(document: document) }
                    .sheet(isPresented: $showingTutorialPresets) { TutorialPresetView(document: document) }
                    .sheet(isPresented: $showingImageComparison) { ImageComparisonView(document: document) }
                if document.preparingPixels { ProgressView().controlSize(.small); Button(L10n.text("取消图像处理")) { document.cancelPixelPreparation() } }
                if let error = document.pixelPreparationError { Text(error).font(.caption).foregroundStyle(.orange) }
                if document.arrangingMarks { ProgressView().controlSize(.small); Button(L10n.text("取消对齐")) { document.cancelArrangement() } }
                if let error = document.arrangementError { Text(error).font(.caption).foregroundStyle(.orange) }
                if activeTool.isShape {
                    Text(L10n.text("形状")).foregroundStyle(Palette.muted)
                    ForEach(AnnotationTool.shapes) { tool in
                        option(tool.title, symbol: tool.symbol, selected: activeTool == tool) {
                            if document.selectingMark { document.changeSelectedShape(to: tool) }
                            else { document.tool = tool }
                        }
                    }
                    separator
                }
                if activeTool == .mosaic {
                    Text(L10n.text("马赛克")).foregroundStyle(Palette.muted)
                    ForEach(MosaicStyle.allCases) { style in
                        Button { document.mosaicStyle = style } label: {
                            Label(style.title, systemImage: style.symbol).padding(.horizontal, 8).frame(height: 29)
                                .background(document.mosaicStyle == style ? Palette.ice.opacity(0.16) : Palette.chrome.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    separator
                    Text(L10n.text("强度")).foregroundStyle(Palette.muted)
                    Slider(value: $document.mosaicStrength, in: 1...5, step: 1).frame(width: 100)
                } else {
                    if activeTool == .icon {
                        Text(L10n.text("图标")).foregroundStyle(Palette.muted)
                        Menu {
                            ForEach(VectorIcon.allCases) { icon in Button { document.icon = icon } label: { Label(icon.title, systemImage: icon.symbol) } }
                        } label: { Label(document.icon.title, systemImage: document.icon.symbol) }.fixedSize()
                        separator
                    }
                    if activeTool != .redact {
                        Text(L10n.text("颜色")).foregroundStyle(Palette.muted)
                        ForEach(AnnotationColor.allCases) { preset in
                            Button { document.selectColor(preset) } label: {
                                Circle().fill(Color(nsColor: preset.color)).frame(width: 16, height: 16)
                                    .padding(3).overlay(Circle().strokeBorder(document.color == preset && document.customColor == nil ? Palette.ice : Palette.chrome.opacity(0.25)))
                            }.buttonStyle(.plain).help(preset.title)
                        }
                        CompactColorWell(color: Binding(get: { document.customColor ?? document.color.color },
                                                        set: { document.customColor = $0 }))
                            .frame(width: 24, height: 24).clipped()
                        separator
                    }
                    if activeTool.isClosedShape {
                        ForEach(AnnotationFill.allCases) { fill in
                            option(fill.title, symbol: fill.symbol, selected: document.fill == fill) { document.fill = fill }
                        }
                        separator
                    }
                    if activeTool == .icon {
                        Text(L10n.text("单击尺寸")).foregroundStyle(Palette.muted)
                        Slider(value: $document.iconSize, in: 24...180).frame(width: 95)
                    } else if activeTool == .text || activeTool == .replace || activeTool == .step {
                        if activeTool != .step {
                            Picker(L10n.text("样式"), selection: $document.textStyle) { ForEach(AnnotationTextStyle.allCases) { Text($0.title).tag($0) } }.frame(width: 100)
                            if document.selectedMark != nil { TextField(L10n.text("文字"), text: $document.selectedText).frame(width: 150) }
                        }
                        Text(L10n.text("字号")).foregroundStyle(Palette.muted)
                        Slider(value: $document.fontSize, in: 8...96).frame(width: 95)
                    } else if activeTool == .curvedArrow {
                        Text(L10n.text("弯曲")).foregroundStyle(Palette.muted); Slider(value: $document.curvature, in: -0.8...0.8).frame(width: 100)
                    } else if activeTool == .image {
                        Text(L10n.text("透明度")); Slider(value: $document.opacity, in: 0...1).frame(width: 100)
                        Text(L10n.text("宽度"))
                        Slider(value: Binding(get: { document.overlayPixelWidth }, set: { document.resizeSelectedImage(toWidth: $0) }),
                               in: 1...CGFloat(document.original.width)).frame(width: 140)
                    } else if activeTool == .erase {
                        Text(L10n.text("修复画笔"))
                    } else if activeTool == .magnify {
                        Text(L10n.text("放大倍率")).foregroundStyle(Palette.muted)
                        Slider(value: $document.mosaicStrength, in: 1.2...5).frame(width: 95)
                    } else if activeTool != .redact {
                        Text(L10n.text("粗细")).foregroundStyle(Palette.muted)
                        Slider(value: $document.lineWidth, in: 2...20).frame(width: 95)
                    } else {
                        Label(L10n.text("实色遮盖"), systemImage: "rectangle.fill").foregroundStyle(Palette.muted)
                    }
                }
            }.font(.system(size: 13)).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, StudioMetrics.contentInset).frame(height: 48)
        }.scrollIndicators(.automatic).background(Palette.chrome.opacity(0.025))
    }
    private var separator: some View { Divider().frame(height: 22).padding(.horizontal, 3) }
    private func option(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        StudioIconButton(title: title, symbol: symbol, selected: selected, action: action)
    }
}

struct EditorView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var store: CaptureStore
    @ObservedObject var document: AnnotationDocument
    let record: CaptureRecord
    let parent: NSWindow
    @State private var showText = false
    @StateObject private var textDraft = EditorTextDraft()
    @StateObject private var copyFeedback = ImageDeliveryFeedback()
    @State private var zoom: CGFloat? = nil
    @State private var displayedZoom: CGFloat = 1
    @ObservedObject private var toolbarPreferences = ToolbarPreferences.shared
    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar {
                EditorBarTitle(title: record.title, detail: L10n.text("\(document.original.width) × \(document.original.height) 像素"))
            } tools: {
                zoomControls
                StudioIconButton(title: L10n.text("裁剪与清理"), symbol: "crop") { app.showCleanup(document, parent: parent, mode: CaptureMode(rawValue: record.mode) ?? .region) }
                Button(showText ? L10n.text("收起文字") : L10n.text("识别文字")) { showText.toggle() }
                    .buttonStyle(StudioButtonStyle(command: true)).frame(width: 88)
            }
            HSplitView {
                CanvasRepresentable(document: document, zoom: $zoom, displayedZoom: $displayedZoom)
                    .frame(minWidth: 360)
                if showText {
                    EditorTextInspector(app: app, store: store, document: document, draft: textDraft, record: record,
                                        close: { showText = false })
                        .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 6) {
                StudioIconButton(title: L10n.text("选择标注"), symbol: "cursorarrow.rays", selected: document.selectingMark) {
                    document.selectingMark = true
                }.help(L10n.text("选中标注后可拖动、改属性或按 Delete 删除"))
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(toolbarPreferences.editorTools) { tool in
                            StudioIconButton(title: tool.title, symbol: tool.symbol, selected: document.tool == tool && !document.selectingMark) {
                                document.tool = tool; document.selectingMark = false
                            }.help(tool == .redact ? L10n.text("导出时以黑色像素覆盖；历史仍保留原图") : tool.title)
                        }
                    }
                }.scrollIndicators(.automatic).frame(height: 38)
                Menu {
                    Button(L10n.text("叠加图片…")) { document.importOverlay() }
                    Button(L10n.text("导出前后对照 GIF…")) { document.exportComparison() }
                    Divider()
                    Button(L10n.text("旋转、缩放与拼图…")) { document.renderForDelivery { image in app.showTransform(image) } }
                    Button(L10n.text("裁剪与清理…")) { app.showCleanup(document, parent: parent, mode: CaptureMode(rawValue: record.mode) ?? .region) }
                    Divider()
                    ForEach(AnnotationTool.allCases.filter { $0 != .image && $0 != .replace && !toolbarPreferences.editorTools.contains($0) }) { tool in Button(tool.title) { document.tool = tool; document.selectingMark = false } }
                    Divider()
                    ForEach(AnnotationColor.allCases) { color in Button(color.title) { document.color = color } }
                } label: { Image(systemName: "ellipsis").frame(width: 22) }.menuStyle(.borderlessButton).fixedSize()
                Divider().frame(height: 25).padding(.horizontal, 4)
                StudioIconButton(title: L10n.text("撤销"), symbol: "arrow.uturn.backward") { document.undo() }
                    .disabled(!document.canUndo).keyboardShortcut("z", modifiers: .command)
                StudioIconButton(title: L10n.text("重做"), symbol: "arrow.uturn.forward") { document.redo() }
                    .disabled(!document.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            }.padding(.horizontal, StudioMetrics.contentInset).padding(.vertical, 6).background(Palette.paper)
            Divider()
            HistoryAnnotationControls(document: document).background(Palette.paper)
            Divider()
            if let error = document.pixelPreparationError ?? document.arrangementError ?? copyFeedback.state.error { EditorStatusLine(text: error) }
            else if let notice = app.notice { EditorStatusLine(text: notice) }
            StudioActionBar {
                StudioMenu(L10n.text("图片操作")) {
                    Button(L10n.text("存入历史副本")) { storeEditableCopy() }.disabled(app.isSavingImageHistory(document) || copyFeedback.state.busy)
                    Button(L10n.text("贴到屏幕")) { document.renderForDelivery { image in app.pin(image) } }
                }.fixedSize().disabled(copyFeedback.state.busy)
                ActionButton(title: L10n.text("美化"), symbol: "sparkles", compact: true, action: beautifyAction)
                    .disabled(copyFeedback.state.busy || document.preparingPixels || document.replacingOCR || document.arrangingMarks)
                    .help(L10n.text("美化当前图片 ⇧⌘B"))
                Spacer(minLength: 8)
                if copyFeedback.state.busy {
                    StudioImageDeliveryStatus(state: copyFeedback.state, cancel: { copyFeedback.cancel() })
                } else if app.isSavingImageHistory(document) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在存入历史副本…")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if let status = app.imageExportStatus(in: parent) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button(L10n.text("取消保存")) { app.cancelImageExport(in: parent) }.controlSize(.small)
                } else if document.preparingPixels {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消处理")) { document.cancelPixelPreparation() }.controlSize(.small)
                } else if copyFeedback.state.message != nil {
                    StudioImageDeliveryStatus(state: copyFeedback.state)
                }
                ActionButton(title: L10n.text("保存"), symbol: "square.and.arrow.down", compact: true) { document.renderForDelivery { image in app.save(image, parent: parent) } }.disabled(copyFeedback.state.busy || app.imageExportStatus(in: parent) != nil || document.preparingPixels || document.replacingOCR || document.arrangingMarks)
                    .keyboardShortcut(textDraft.editingText ? nil : KeyboardShortcut("s", modifiers: .command))
                ActionButton(title: L10n.text("复制"), symbol: "doc.on.doc", primary: true, compact: true) { document.renderForDelivery { image in app.copy(image, backingScale: document.backingScale, feedback: copyFeedback) } }.disabled(copyFeedback.state.busy || app.imageExportStatus(in: parent) != nil || app.isSavingImageHistory(document) || document.preparingPixels || document.replacingOCR || document.arrangingMarks)
                    .keyboardShortcut(textDraft.editingText ? nil : KeyboardShortcut("c", modifiers: .command))
            }
        }.background(Palette.ink).foregroundStyle(Palette.white)
            .frame(minWidth: 760, minHeight: 540)
            .onAppear { (parent as? ImageEditorWindow)?.beautifyCurrentImage = beautifyAction }
            .onChange(of: document.renderRevision) { _, _ in
                if !copyFeedback.state.busy { copyFeedback.invalidate() }
            }
            .onDisappear {
                (parent as? ImageEditorWindow)?.beautifyCurrentImage = nil
                copyFeedback.invalidate()
                document.cancelPixelPreparation(); document.cancelOCRReplacement(); document.cancelArrangement()
            }

    }
    private var beautifyAction: () -> Void {
        { [weak document = document, weak app = app, weak feedback = copyFeedback] in
            guard let document, let app, let feedback, !feedback.state.busy else { return }
            document.renderForDelivery { [weak app] image in app?.showBeautifier(image) }
        }
    }
    private func storeEditableCopy() {
        document.renderForDelivery { image in
            let snapshot = CaptureProjectSnapshot(document)
            app.saveEdited(image, document: document) { result in
                if case .success = result { (parent as? ImageEditorWindow)?.markPreserved(snapshot) }
            }
        }
    }
    private var zoomControls: some View {
        HStack(spacing: 7) {
                    StudioIconButton(title: L10n.text("缩小图片"), symbol: "minus.magnifyingglass") { zoom = max(0.1, displayedZoom / 1.25) }
                        .help(L10n.text("缩小图片 ⌘−")).disabled(displayedZoom <= 0.1).keyboardShortcut("-", modifiers: .command)
                    Menu {
                        Button("100%") { zoom = 1 }.keyboardShortcut("1", modifiers: .command)
                        Button(L10n.text("适应窗口")) { zoom = nil }
                        Divider()
                        ForEach([25, 50, 150, 200, 300, 400, 800], id: \.self) { percent in
                            Button("\(percent)%") { zoom = CGFloat(percent) / 100 }
                        }
                    } label: { Text("\(Int((displayedZoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 42) }
                        .menuStyle(.borderlessButton).fixedSize().help(L10n.text("图片显示比例；100% 按原图像素显示"))
                    StudioIconButton(title: L10n.text("放大图片"), symbol: "plus.magnifyingglass") { zoom = min(8, displayedZoom * 1.25) }
                        .help(L10n.text("放大图片 ⌘+；也可用触控板捏合缩放")).disabled(displayedZoom >= 8).keyboardShortcut("=", modifiers: .command)
                    Button(L10n.text("适应")) { zoom = nil }.keyboardShortcut("0", modifiers: .command)
                }.font(.system(size: 13)).buttonStyle(StudioButtonStyle(command: true))
    }
}

final class PinnedImagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var point = frame.origin
        switch event.keyCode {
        case 123: point.x -= step
        case 124: point.x += step
        case 125: point.y -= step
        case 126: point.y += step
        case 53: close(); return
        default: super.keyDown(with: event); return
        }
        setFrameOrigin(point)
    }
}

// Handle the image's mouse events directly: SwiftUI gestures and hosting-view
// hit testing must not decide whether a borderless panel can be moved.
final class PinnedImageContentView: NSImageView {
    var close: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { close(); return }
        window?.makeKey()
        window?.performDrag(with: event)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

private struct PinnedImageSurface: NSViewRepresentable {
    let image: NSImage
    let close: () -> Void
    func makeNSView(context: Context) -> PinnedImageContentView {
        let view = PinnedImageContentView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setAccessibilityLabel(L10n.text("贴到屏幕的图片"))
        view.toolTip = L10n.text("拖动图片移动；双击关闭")
        return view
    }
    func updateNSView(_ view: PinnedImageContentView, context: Context) {
        view.image = image; view.close = close
    }
}

struct PinView: View {
    let image: NSImage
    let close: () -> Void
    var setOpacity: (Double) -> Void = { _ in }
    var lock: () -> Void = {}
    @State private var opacity = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    Text(L10n.text("拖动图片移动")).lineLimit(1)
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Slider(value: $opacity, in: 0.2...1).frame(width: 64).help(L10n.text("透明度"))
                    .onChange(of: opacity) { _, value in setOpacity(value) }
                Button(action: lock) { Image(systemName: "cursorarrow.rays") }
                    .help(L10n.text("鼠标穿透：点击将操作下方窗口，贴图暂不可拖动；从菜单栏解锁"))
                Button(action: close) { Image(systemName: "xmark") }.help(L10n.text("关闭贴图"))
            }.font(.system(size: 10)).padding(.horizontal, 8).frame(height: 30)
                .buttonStyle(.plain).foregroundStyle(Palette.white)
            PinnedImageSurface(image: image, close: close)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }.background(GlassSurface()).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.ice.opacity(0.4)).allowsHitTesting(false))
    }
}

struct CaptureToast: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(Palette.ice)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.white)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(GlassSurface())
            .clipShape(Capsule()).overlay(Capsule().strokeBorder(Palette.chrome.opacity(0.18)))
    }
}
