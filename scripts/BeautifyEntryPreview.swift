// Manual visual-review host. Uses only temporary media, an isolated home,
// a named pasteboard and production views; no tests or quality diagnostics.
import AppKit
import SwiftUI
@testable import DeskCapture

@main enum BeautifyEntryPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = BeautifyEntryPreviewDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class BeautifyEntryPreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasPrefix("/tmp/deskcapture-beautify-") else {
            fatalError("Use an isolated /tmp/deskcapture-beautify- home")
        }
        Task {
            do {
            let root = URL(fileURLWithPath: home, isDirectory: true)
            let store = CaptureStore(directory: root.appendingPathComponent("history", isDirectory: true), pruneOnInit: false)
            let board = NSPasteboard(name: .init("DeskCapture.BeautifyReview.\(UUID())"))
            let coordinator = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
            let largeBeauty = CommandLine.arguments.contains("--large-beautify")
            let image = fixture(scale: largeBeauty ? 4 : 1)
            let record = try await store.addAsync(image, mode: .region)
            if CommandLine.arguments.contains("--render") {
                let output = root.appendingPathComponent("renders")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let appearances: [(String, ColorScheme)]
                if CommandLine.arguments.contains("--appearance-dark") { appearances = [("dark", .dark)] }
                else if CommandLine.arguments.contains("--appearance-light") { appearances = [("light", .light)] }
                else if CommandLine.arguments.contains("--dark-first") { appearances = [("dark", .dark), ("light", .light)] }
                else { appearances = [("light", .light), ("dark", .dark)] }
                for (suffix, scheme) in appearances {
                    NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                    if CommandLine.arguments.contains("--beautify-chooser-review") {
                        await render(BeautifyWorkspaceView(store: store, pasteboard: board, copy: { _ in }, save: { _ in }, close: {})
                            .environment(\.colorScheme, scheme), size: .init(width: 820, height: 560),
                            name: "beautify-source-entry-\(suffix)", output: output)
                        // Explicit error-copy display only; no invalid file is opened.
                        await render(Label("请选择不超过 100 MB 的本地背景图片。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).padding(16).frame(width: 300, height: 100)
                            .background(Palette.paper).environment(\.colorScheme, scheme),
                            size: .init(width: 300, height: 100), name: "beautify-background-limit-\(suffix)", output: output)
                        continue
                    }
                    if CommandLine.arguments.contains("--editor-beautify-entry") {
                        await render(EditorView(app: coordinator, store: store, document: AnnotationDocument(image: image),
                            record: record, parent: NSWindow()).environment(\.colorScheme, scheme),
                            size: .init(width: 760, height: 540), name: "editor-beautify-entry-\(suffix)", output: output)
                        continue
                    }
                    if CommandLine.arguments.contains("--original-copy-feedback") {
                        for (name, text, kind) in [
                            ("copied", "原片文件已复制", StudioMessageKind.information),
                            ("screen", "屏幕原片文件已复制", .information),
                            ("failed", "原片文件未能复制，请重试或在 Finder 中显示。", .error)
                        ] {
                            await render(StudioMessage(text: text, kind: kind, dismiss: {})
                                .padding(16).frame(width: name == "failed" ? 380 : 760, height: 88)
                                .background(Palette.ink).environment(\.colorScheme, scheme),
                                size: .init(width: name == "failed" ? 380 : 760, height: 88),
                                name: "original-copy-\(name)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--camera-import-feedback") {
                        for cancelling in [false, true] {
                            await render(StudioActionBar {
                                VideoExportProgressView(progress: nil, status: "正在导入画中画…", cancelling: cancelling, cancel: {})
                            }.controlSize(.small).environment(\.colorScheme, scheme),
                                size: .init(width: 760, height: 64),
                                name: "camera-import-\(cancelling ? "cancelling" : "preparing")-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--video-export-progress") {
                        for (name, status, progress, cancelling) in [
                            ("choosing", "选择保存位置…", Optional<Double>.none, false),
                            ("subtitles", "正在导出字幕…", nil, false),
                            ("video", "正在处理…", 0.42, false),
                            ("cancelling", "正在导出字幕…", nil, true)
                        ] {
                            await render(StudioActionBar {
                                VideoExportProgressView(progress: progress, status: status, cancelling: cancelling, cancel: {})
                            }.controlSize(.small).environment(\.colorScheme, scheme),
                                size: .init(width: 760, height: 64), name: "video-export-\(name)-\(suffix)", output: output)
                        }
                        await render(StudioActionBar {
                            StudioExportReceipt(url: URL(fileURLWithPath: "/tmp/DeskCapture.srt"), reveal: { _ in })
                            Spacer(minLength: 8)
                            Button("保存编辑") {}
                            Button("导出成片…") {}
                        }.controlSize(.small).environment(\.colorScheme, scheme),
                            size: .init(width: 760, height: 64), name: "video-export-receipt-\(suffix)", output: output)
                        continue
                    }
                    if CommandLine.arguments.contains("--editor-copy-feedback") {
                        let states: [(String, ImageDeliveryState)] = [
                            ("copying", .init(status: "正在复制图片…")),
                            ("cancelling", .init(status: "正在取消…", cancelling: true)),
                            ("copied", .init(message: "图片已复制")),
                            ("failed", .init(error: "剪贴板已有新的内容，未覆盖。"))
                        ]
                        for (name, state) in states {
                            // Production status components in an explicit
                            // footer composition; no copy task is executed.
                            await render(VStack(spacing: 0) {
                                if let error = state.error { EditorStatusLine(text: error) }
                                StudioActionBar {
                                    StudioMenu("图片操作") {}.disabled(state.busy)
                                    ActionButton(title: "美化", symbol: "sparkles", compact: true) {}.disabled(state.busy)
                                    Spacer(minLength: 8)
                                    StudioImageDeliveryStatus(state: state)
                                    ActionButton(title: "保存", symbol: "square.and.arrow.down", compact: true) {}.disabled(state.busy)
                                    ActionButton(title: "复制", symbol: "doc.on.doc", primary: true, compact: true) {}.disabled(state.busy)
                                }
                            }.environment(\.colorScheme, scheme), size: .init(width: 760, height: 100),
                                name: "editor-copy-\(name)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--scroll-handoff") {
                        // A display-only fixture: never start polling, finish,
                        // copy, save or trigger a capture/session operation.
                        let stitcher = try await Task.detached {
                            let value = try ScrollStitcher(detectsFixedEdges: false)
                            try value.append(image)
                            return value
                        }.value
                        let model = ScrollCapture(stitcher: stitcher)
                        await render(ScrollHUD(scroll: model, finish: {}, save: {}, cancel: {}, edit: {})
                            .environment(\.colorScheme, scheme), size: ScrollHUD.initialSize,
                            name: "scroll-handoff-hud-\(suffix)", output: output)
                        continue
                    }
                    if CommandLine.arguments.contains("--scroll-progress") {
                        for (index, progress) in ScrollDeliveryProgress.allCases.enumerated() {
                            await render(ScrollDeliveryProgressView(progress: progress)
                                .padding(16).frame(width: 344, height: 88)
                                .background(OpticalPanel(radius: 16)).environment(\.colorScheme, scheme),
                                size: .init(width: 344, height: 88), name: "scroll-progress-\(index)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--video-budget") {
                        for name in ["filters-off", "sharpen", "deband", "custom"] {
                            await render(VideoBudgetReview(mode: name).environment(\.colorScheme, scheme),
                                size: .init(width: 380, height: 440), name: "video-budget-\(name)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--video-motion") {
                        for name in ["screen", "both-optics", "camera-off", "camera-on", "reframed"] {
                            await render(VideoMotionReview(mode: name).environment(\.colorScheme, scheme),
                                size: .init(width: 380, height: 600), name: "video-motion-\(name)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--video-canvas") {
                        for (name, background, automatic) in [("background", true, false), ("no-background", false, false), ("automatic", true, true)] {
                            await render(VideoCanvasReview(background: background, automatic: automatic).environment(\.colorScheme, scheme),
                                size: .init(width: 380, height: 460), name: "video-canvas-\(name)-\(suffix)", output: output)
                        }
                        await render(VideoBackgroundPalette(selected: .aurora, choose: { _ in }).environment(\.colorScheme, scheme),
                            size: .init(width: 300, height: 320), name: "video-background-palette-\(suffix)", output: output)
                        continue
                    }
                    if CommandLine.arguments.contains("--quick-looks") {
                        for (name, size) in [("minimum", CGSize(width: 820, height: 560)), ("regular", .init(width: 960, height: 660))] {
                            await render(BeautifyResultView(source: image, copy: { _ in }, save: { _ in }, close: {})
                                .environment(\.colorScheme, scheme), size: size,
                                name: "quick-looks-\(name)-\(suffix)", output: output)
                        }
                        await render(BeautifyLookPicker(source: image, layout: .square, selected: .clear, apply: { _ in })
                            .frame(width: 260, height: 210)
                            .padding(20).background(Palette.paper).environment(\.colorScheme, scheme),
                            size: .init(width: 300, height: 250), name: "quick-looks-square-\(suffix)", output: output)
                        continue
                    }
                    if CommandLine.arguments.contains("--image-delivery") {
                        let states: [(String, ImageDeliveryState)] = [
                            ("saving", .init(status: "正在保存图片…")),
                            ("copying", .init(status: "正在复制图片…")),
                            ("cancelling", .init(status: "正在取消…", cancelling: true)),
                            ("saved", .init(savedURL: store.url(for: record))),
                            ("copied", .init(message: "图片已复制")),
                            ("failure", .init(error: "保存失败：演示目标不可写，请选择其他位置。"))
                        ]
                        for (name, state) in states {
                            await render(BeautifyResultView(source: image, copy: { _ in }, save: { _ in }, close: {}, output: state)
                                .environment(\.colorScheme, scheme), size: .init(width: 820, height: 560),
                                name: "image-delivery-\(name)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--video-receipt") {
                        // A real, generated PNG fixture models a saved video frame.
                        // This reviews the shared receipt, not a video export session.
                        let delivered = root.appendingPathComponent("DeskCapture 演示视频截取帧 — 完整文件名称.png")
                        if !FileManager.default.fileExists(atPath: delivered.path) {
                            let input = store.url(for: record)
                            try await Task.detached { try FileManager.default.copyItem(at: input, to: delivered) }.value
                        }
                        for width in [780.0, 1120.0] {
                            await render(StudioActionBar {
                                Text("未保存修改").font(.system(size: 12)).foregroundStyle(Palette.muted)
                                StudioExportReceipt(url: delivered, reveal: { _ in })
                                Spacer(minLength: 8)
                                Button("保存编辑") {}.buttonStyle(StudioButtonStyle(command: true))
                                Button("导出成片…") {}.buttonStyle(StudioButtonStyle(primary: true, command: true))
                            }.environment(\.colorScheme, scheme), size: .init(width: width, height: 64),
                                name: "video-receipt-\(Int(width))-\(suffix)", output: output)
                        }
                        continue
                    }
                    if CommandLine.arguments.contains("--capture-beautify") {
                        let state = InlineCaptureState()
                        state.pixelWidth = image.width; state.pixelHeight = image.height; state.scrollSelectionReady = true
                        for (name, mode, width, inputOnly) in [
                            ("region", CaptureMode.region, 660.0, false),
                            ("region-narrow", .region, 420.0, false),
                            ("window", .window, 660.0, false),
                            ("source-only", .region, 420.0, true),
                            ("recording", .recording, 360.0, false),
                            ("scrolling", .scrolling, 460.0, false)
                        ] {
                            await render(InlineCaptureToolbar(document: AnnotationDocument(image: image), state: state, mode: mode,
                                complete: { _ in }, cancel: {}, focus: {}, resizeSelection: { _, _ in }, changeAspectRatio: { _ in },
                                recorder: coordinator.recorder, inputOnly: inputOnly, colorPasteboard: board)
                                .environment(\.colorScheme, scheme), size: .init(width: width, height: 50),
                                name: "capture-\(name)-\(suffix)", output: output)
                        }
                        continue
                    }
                    if largeBeauty {
                        await render(BeautifyWorkspaceView(store: store, pasteboard: board, source: image, copy: { _ in }, save: { _ in }, close: {})
                            .environment(\.colorScheme, scheme), size: .init(width: 820, height: 560), name: "large-beautify-\(suffix)", output: output)
                        continue
                    }
                    await render(BeautifyWorkspaceView(store: store, pasteboard: board, copy: { _ in }, save: { _ in }, close: {})
                        .environment(\.colorScheme, scheme), size: .init(width: 820, height: 560), name: "entry-\(suffix)", output: output)
                    await render(BeautifyWorkspaceView(store: store, pasteboard: board, source: image, copy: { _ in }, save: { _ in }, close: {})
                        .environment(\.colorScheme, scheme), size: .init(width: 820, height: 560), name: "beautify-\(suffix)", output: output)
                    await render(StatusMenuView(app: coordinator, previewState: .init(), perform: { _ in }, close: {})
                        .environment(\.colorScheme, scheme), size: nil, name: "menu-\(suffix)", output: output)
                    await render(CompactLauncherView(app: coordinator, store: store).environment(\.colorScheme, scheme),
                        size: nil, name: "launcher-\(suffix)", output: output)
                    await render(HistoryView(app: coordinator, store: store).environment(\.colorScheme, scheme),
                        size: .init(width: 600, height: 440), name: "history-\(suffix)", output: output)
                    await render(EditorView(app: coordinator, store: store, document: AnnotationDocument(image: image),
                        record: record, parent: NSWindow()).environment(\.colorScheme, scheme),
                        size: .init(width: 760, height: 540), name: "editor-\(suffix)", output: output)
                }
                print(output.path)
                NSApp.terminate(nil)
                return
            }
            let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
            appMenu.addItem(withTitle: "退出预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 710),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            self.window = window
            window.title = "DeskCapture · 美化入口设计预览（隔离数据）"
            window.contentMinSize = .init(width: 820, height: 610)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BeautifyReviewPages(app: coordinator, store: store,
                pasteboard: board, image: image, record: record, window: window))
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            } catch {
                print("Preview unavailable: \(error.localizedDescription)")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !CommandLine.arguments.contains("--render") }
    private func render<V: View>(_ view: V, size: CGSize?, name: String, output: URL) async {
        let host = NSHostingView(rootView: view)
        let fitted = size ?? host.fittingSize
        let window = NSWindow(contentRect: .init(origin: .zero, size: fitted), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.setContentSize(fitted); window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(750))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            await Task.detached {
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: output.appendingPathComponent(name + ".png"))
                }
            }.value
        }
        window.orderOut(nil); window.contentView = nil
    }
    private func fixture(scale: Int = 1) -> CGImage {
        let context = CGContext(data: nil, width: 900 * scale, height: 560 * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(NSColor(calibratedWhite: 0.98, alpha: 1).cgColor)
        context.fill(.init(x: 0, y: 0, width: 900, height: 560))
        context.setFillColor(NSColor.systemIndigo.cgColor)
        context.fill(.init(x: 48, y: 48, width: 6, height: 464))
        for index in 0..<5 {
            context.setFillColor(NSColor.systemIndigo.withAlphaComponent(0.18 + Double(index) * 0.10).cgColor)
            context.fill(.init(x: 96, y: 90 + index * 82, width: 640 - index * 60, height: 32))
        }
        return context.makeImage()!
    }
}

private struct VideoCanvasReview: View {
    @State private var options: RecordingEffectsOptions
    init(background: Bool, automatic: Bool) {
        var value = RecordingEffectsOptions()
        value.background = background
        if automatic { var framing = VideoReframingOptions(); framing.enabled = true; value.reframing = framing }
        _options = State(initialValue: value)
    }
    var body: some View {
        ScrollView {
            VideoCanvasControls(options: $options)
                .environment(\.videoInspectorFields, true).toggleStyle(VideoToggleStyle()).controlSize(.small)
                .font(.system(size: 13)).foregroundStyle(Palette.white).padding(20)
        }.frame(width: 380, height: 460).background(Palette.paper)
    }
}

private struct VideoMotionReview: View {
    let mode: String
    @State private var effects = RecordingEffectsOptions()
    @State private var lenses: [RecordingLens] = []
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var zoom = 2.0
    @State private var length = 2.0
    @State private var optics: RecordingOpticsOptions
    init(mode: String) {
        self.mode = mode
        var effects = RecordingEffectsOptions()
        if mode == "reframed" {
            var framing = VideoReframingOptions(); framing.enabled = true; effects.reframing = framing
        }
        _effects = State(initialValue: effects)
        var value = RecordingOpticsOptions()
        value.motionBlur = true; value.cameraMotionBlur = mode != "camera-off"
        _optics = State(initialValue: value)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if mode == "screen" {
                    VideoZoomControls(options: $effects, lenses: $lenses, x: $x, y: $y, zoom: $zoom,
                        lensDuration: $length, hasInteractions: true, trimStart: 0, trimEnd: 10,
                        currentTime: { 1 }, initiallyExpanded: true)
                } else if mode == "reframed" {
                    VideoCanvasControls(options: $effects)
                    let availability = VideoMotionAvailability(options: effects, lenses: lenses, hasInteractions: true, cameraReady: false)
                    if availability.manualZoom {
                        VideoZoomControls(options: $effects, lenses: $lenses, x: $x, y: $y, zoom: $zoom,
                            lensDuration: $length, hasInteractions: true, trimStart: 0, trimEnd: 10,
                            currentTime: { 1 }, initiallyExpanded: true)
                    }
                    if availability.optics {
                        RecordingOpticsEditor(options: $optics, screenMotionAvailable: availability.screenOptics,
                            cameraMotionAvailable: availability.cameraOptics, initiallyExpanded: true)
                    }
                } else {
                    RecordingOpticsEditor(options: $optics, screenMotionAvailable: mode == "both-optics",
                        cameraMotionAvailable: true, initiallyExpanded: true)
                }
            }.environment(\.videoInspectorFields, true).toggleStyle(VideoToggleStyle()).controlSize(.small)
                .font(.system(size: 13)).foregroundStyle(Palette.white).padding(20)
        }.frame(width: 380, height: 600).background(Palette.paper)
    }
}

private struct VideoBudgetReview: View {
    @State private var options: VideoQualityOptions
    init(mode: String) {
        var value = VideoQualityOptions()
        value.sharpen = mode == "sharpen"; value.deband = mode == "deband"
        if mode == "custom" { value.memoryMiB = 768 }
        _options = State(initialValue: value)
    }
    var body: some View {
        ScrollView {
            VideoQualityEditor(options: $options, initiallyExpanded: true)
                .environment(\.videoInspectorFields, true).toggleStyle(VideoToggleStyle()).controlSize(.small)
                .font(.system(size: 13)).foregroundStyle(Palette.white).padding(20)
        }.frame(width: 380, height: 440).background(Palette.paper)
    }
}

private struct BeautifyReviewPages: View {
    let app: AppCoordinator
    let store: CaptureStore
    let pasteboard: NSPasteboard
    let image: CGImage
    let record: CaptureRecord
    let window: NSWindow
    @State private var page = "选图"
    @State private var dark = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("预览页面", selection: $page) {
                    ForEach(["选图", "美化", "主菜单", "快捷面板", "历史", "编辑器"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("深色", isOn: $dark).toggleStyle(.checkbox)
            }.padding(10)
            Divider()
            Group {
                switch page {
                case "选图": BeautifyWorkspaceView(store: store, pasteboard: pasteboard, copy: { _ in }, save: { _ in }, close: {})
                case "美化": BeautifyWorkspaceView(store: store, pasteboard: pasteboard, source: image, copy: { _ in }, save: { _ in }, close: {})
                case "主菜单": StatusMenuView(app: app, previewState: .init(), perform: { _ in }, close: {})
                case "快捷面板": CompactLauncherView(app: app, store: store)
                case "历史": HistoryView(app: app, store: store)
                default: EditorView(app: app, store: store, document: AnnotationDocument(image: image), record: record, parent: window)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.environment(\.colorScheme, dark ? .dark : .light)
    }
}
