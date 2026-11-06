// Renders production UI with generated media, a named pasteboard and an isolated home.
import AppKit
import SwiftUI
import AVFoundation
#if UI_REVIEW_MODULE
@testable import DeskCapture
#endif

@main enum UILayoutPreview {
    @MainActor static var previewWindow: NSWindow?
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = UILayoutPreviewDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }

    @MainActor static func runPreview() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["CFFIXED_USER_HOME"], home.hasPrefix("/tmp/deskcapture-ui-"),
              let output = env["DESKCAPTURE_DIAGNOSTIC_DIR"], output.hasPrefix(home) else {
            fatalError("UI previews require an isolated /tmp/deskcapture-ui- home and output directory")
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CaptureStore(directory: directory.appendingPathComponent("history", isDirectory: true), pruneOnInit: false)
        let coordinator = AppCoordinator(store: store, imagePasteboard: NSPasteboard(name: .init("DeskCapture.UIReview.\(UUID())")), registerHotKeys: false)
        let image = fixture()
        if CommandLine.arguments.contains("--refinement-only") || env["DESKCAPTURE_UI_REFINEMENT"] == "1" {
            // Visual documents only: do not create recordings or exercise exports.
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                await render(CompactLauncherView(app: coordinator, store: store).environment(\.colorScheme, scheme),
                             size: .init(width: 328, height: 500), name: "refined-launcher-\(suffix)", directory: directory)
                for (name, size) in [("minimum", CGSize(width: 820, height: 560)),
                                     ("regular", CGSize(width: 960, height: 660))] {
                    await render(BeautifyResultView(source: image, copy: { _ in }, save: { _ in }, close: {})
                        .environment(\.colorScheme, scheme), size: size,
                        name: "refined-beautify-\(name)-\(suffix)", directory: directory)
                }
            }
            if CommandLine.arguments.contains("--interactive") || env["DESKCAPTURE_UI_INTERACTIVE"] == "1" {
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 660),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "DeskCapture · UI 精修"
                window.contentMinSize = StudioMetrics.workspaceMinimum
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: BeautifyResultView(source: image, copy: { _ in }, save: { _ in }, close: {}))
                window.center(); window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                previewWindow = window
            }
            print("Refinement UI: \(directory.path)")
            return
        }
        let record = try await store.addAsync(image, mode: .region)
        let document = AnnotationDocument(image: image)
        let notes = SpeakerNotesController()
        notes.text = "录制提词稿\n让每个功能都有清楚的分组、对齐和操作位置。\n这是一份临时的视觉检查稿件。"
        notes.enabled = true
        let tutorial = TutorialRecorder()
        tutorial.steps = [.init(title: "第一步：打开需要截取的窗口", detail: "步骤说明会随着窗口宽度换行，不挤压旁边的操作。", file: "fixture.png", clickX: 0.5, clickY: 0.5)]
        let table = try OCRTableResult.assemble([.init(row: 0, column: 0, rowSpan: 1, columnSpan: 1, text: "项目"),
                                               .init(row: 0, column: 1, rowSpan: 1, columnSpan: 1, text: "数量")])
        let line = OCRLine(text: "订单号 ABC123", bounds: .init(x: 0.1, y: 0.6, width: 0.5, height: 0.1), confidence: 1)
        let ruleStore = SensitiveRuleStore()
        try await ruleStore.save([SensitiveRule()])
        let review = LocalWorkflowReviewInput(image: image, candidates: [.init(line: line, kinds: [], ruleNames: ["订单号"])])
        let video = try await makeVideo(image, directory: directory)
        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            for section in SettingsSection.allCases {
                let key = String(describing: section.id).replacingOccurrences(of: " ", with: "-")
                await render(SettingsView(app: coordinator, initialSection: section).environment(\.colorScheme, scheme),
                             size: .init(width: 760, height: 540), name: "settings-\(key)-\(suffix)", directory: directory)
            }
            let views: [(String, AnyView)] = [
                ("beautify", AnyView(BeautifyResultView(source: image, copy: { _ in }, save: { _ in }, close: {}))),
                ("transform", AnyView(ImageTransformView(source: image, copy: { _ in }, save: { _ in }, close: {}))),
                ("cleanup", AnyView(ImageCleanupView(source: image, copy: { _ in }, save: { _ in }, close: {}))),
                ("repair", AnyView(RepairStudioView(image: image, save: { _ in }, close: {}))),
                ("composition", AnyView(SmartCompositionView(image: image, save: { _ in }, close: {}))),
                ("simplification", AnyView(UISimplificationView(image: image, save: { _ in }, close: {}))),
                ("comparison", AnyView(ImageComparisonView(document: document))),
                ("color", AnyView(ColorAnalysisView(image: image, close: {}))),
                ("presets", AnyView(TutorialPresetView(document: document))),
                ("boundary", AnyView(ContentBoundaryView(document: document))),
                ("notes", AnyView(SpeakerNotesEditor(controller: notes))),
                ("table", AnyView(OCRTableReviewView(source: image, table: table, app: coordinator, close: {}))),
                ("sensitive-batch", AnyView(SensitiveBatchView())),
                ("workflow-review", AnyView(WorkflowSensitiveReviewView(input: review, cancel: {}, confirm: { _ in }))),
                ("workflow", AnyView(LocalWorkflowView(app: coordinator, recipe: .init(), source: image, close: {}))),
                ("tutorial", AnyView(TutorialEditorView(recorder: tutorial, start: {}))),
                ("device", AnyView(DeviceRecordingView(recorder: coordinator.deviceRecorder, refreshOnAppear: false))),
                ("video", AnyView(VideoResultView(url: video, close: {})))
            ]
            if CommandLine.arguments.contains("--interactive") {
                let settings: [(String, AnyView)] = SettingsSection.allCases.map {
                    ("设置 / " + $0.rawValue, AnyView(SettingsView(app: coordinator, initialSection: $0)))
                }
                let pages = settings + views + [
                    ("启动面板", AnyView(CompactLauncherView(app: coordinator, store: store))),
                    ("截图历史", AnyView(HistoryView(app: coordinator, store: store))),
                    ("图片标注", AnyView(EditorView(app: coordinator, store: store, document: document, record: record, parent: NSWindow()))),
                    ("批量图片", AnyView(HistoryBatchView(store: store, scope: [record]))),
                    ("批量录屏", AnyView(RecordingBatchView(recorder: coordinator.recorder, scope: []))),
                    ("分类", AnyView(MediaMetadataEditor(store: .shared, item: .init(id: MediaMetadataKey.capture(record.id), title: "示例素材")))),
                    ("敏感规则", AnyView(SensitiveRulesEditorView(store: ruleStore))),
                    ("字幕模型", AnyView(LocalSpeechModelsView())),
                    ("OCR 改写", AnyView(InlineOCRRewriteView(document: document, done: {}))),
                    ("敏感检查", AnyView(SensitiveReviewView(document: document, done: {}))),
                    ("色板", AnyView(FavoriteColorShelf(store: .shared, document: document, focus: {}))),
                    ("标注样式", AnyView(AnnotationStyleShelf(store: .shared, document: document, tool: .arrow, apply: { _ in })))
                ]
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1160, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "DeskCapture UI Layout Review"
                window.contentView = NSHostingView(rootView: UIReviewGallery(pages: pages))
                window.contentMinSize = .init(width: 1100, height: 740)
                window.isReleasedWhenClosed = false
                window.center()
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                previewWindow = window
                return
            }
            for (name, view) in views {
                if CommandLine.arguments.contains("--touchup") && !["cleanup", "presets", "comparison", "table", "workflow", "repair", "simplification", "tutorial"].contains(name) { continue }
                await render(view.environment(\.colorScheme, scheme), size: .init(width: 820, height: 560), name: "\(name)-\(suffix)", directory: directory)
            }
            if CommandLine.arguments.contains("--touchup") { continue }
            await render(HistoryBatchView(store: store, scope: [record]).environment(\.colorScheme, scheme), size: .init(width: 920, height: 640), name: "batch-history-\(suffix)", directory: directory)
            await render(RecordingBatchView(recorder: coordinator.recorder, scope: []).environment(\.colorScheme, scheme), size: .init(width: 920, height: 640), name: "batch-video-\(suffix)", directory: directory)
            await render(MediaMetadataEditor(store: .shared, item: .init(id: MediaMetadataKey.capture(record.id), title: "具有较长名称的示例素材，用于检查标签、集合与操作排列")).environment(\.colorScheme, scheme), size: .init(width: 580, height: 600), name: "metadata-\(suffix)", directory: directory)
            await render(SensitiveRulesEditorView(store: ruleStore).environment(\.colorScheme, scheme), size: .init(width: 620, height: 660), name: "rules-\(suffix)", directory: directory)
            await render(LocalSpeechModelsView().environment(\.colorScheme, scheme), size: .init(width: 660, height: 420), name: "models-\(suffix)", directory: directory)
            await render(HistoryView(app: coordinator, store: store).environment(\.colorScheme, scheme), size: .init(width: 600, height: 500), name: "history-\(suffix)", directory: directory)
            await render(RecordingLibraryView(app: coordinator).environment(\.colorScheme, scheme), size: .init(width: 600, height: 460), name: "library-\(suffix)", directory: directory)
            await render(CompactLauncherView(app: coordinator, store: store).environment(\.colorScheme, scheme), size: .init(width: 328, height: 490), name: "launcher-\(suffix)", directory: directory)
            await render(StatusMenuView(app: coordinator, perform: { _ in }, close: {}).environment(\.colorScheme, scheme), size: .init(width: 374, height: 660), name: "menu-\(suffix)", directory: directory)
            await render(EditorView(app: coordinator, store: store, document: document, record: record, parent: NSWindow()).environment(\.colorScheme, scheme), size: .init(width: 760, height: 540), name: "editor-\(suffix)", directory: directory)
        }
        if CommandLine.arguments.contains("--app-wide") {
            let emptyStore = CaptureStore(directory: directory.appendingPathComponent("empty-history"), pruneOnInit: false)
            let captureState = InlineCaptureState()
            captureState.pixelWidth = image.width; captureState.pixelHeight = image.height
            captureState.scrollSelectionReady = true
            let paletteBoard = NSPasteboard(name: .init("DeskCapture.UIReview.Colors.\(UUID())"))
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                for item in VideoEditorTool.allCases {
                    await render(VideoResultView(url: video, close: {}, initialTool: item).environment(\.colorScheme, scheme),
                                 size: .init(width: 1120, height: 760), name: "video-\(item.id)-\(suffix)", directory: directory)
                }
                await render(HistoryView(app: coordinator, store: store, initialGallery: false).environment(\.colorScheme, scheme),
                             size: .init(width: 600, height: 440), name: "history-list-\(suffix)", directory: directory)
                await render(HistoryView(app: coordinator, store: emptyStore).environment(\.colorScheme, scheme),
                             size: .init(width: 600, height: 440), name: "history-empty-\(suffix)", directory: directory)
                await render(EditorTextInspector(app: coordinator, store: store, document: document, draft: EditorTextDraft(),
                                                record: record, close: {}).environment(\.colorScheme, scheme),
                             size: .init(width: 320, height: 600), name: "ocr-inspector-\(suffix)", directory: directory)
                for (name, mode, width) in [("capture-toolbar", CaptureMode.region, 660.0),
                                            ("long-capture-toolbar", .scrolling, 460.0)] {
                    await render(InlineCaptureToolbar(document: document, state: captureState, mode: mode,
                        complete: { _ in }, cancel: {}, focus: {}, resizeSelection: { _, _ in },
                        changeAspectRatio: { _ in }, recorder: coordinator.recorder, colorPasteboard: paletteBoard)
                        .environment(\.colorScheme, scheme), size: .init(width: width, height: 50),
                        name: "\(name)-\(suffix)", directory: directory)
                }
                await render(ScrollHUD(scroll: coordinator.scrollCapture, finish: {}, save: {}, cancel: {})
                    .environment(\.colorScheme, scheme), size: ScrollHUD.initialSize,
                    name: "long-capture-panel-\(suffix)", directory: directory)
                await render(RecordingHUD(recorder: coordinator.recorder, stop: {}).environment(\.colorScheme, scheme),
                             size: .init(width: 346, height: 44), name: "recording-panel-\(suffix)", directory: directory)
                let overview: [(String, AnyView, CGSize)] = [
                    ("捕获历史", AnyView(HistoryView(app: coordinator, store: store)), .init(width: 760, height: 540)),
                    ("录制设置", AnyView(SettingsView(app: coordinator, initialSection: .recording)), .init(width: 760, height: 540)),
                    ("图片编辑", AnyView(EditorView(app: coordinator, store: store, document: document, record: record, parent: NSWindow())), .init(width: 760, height: 540)),
                    ("图片工作台", AnyView(BeautifyResultView(source: image, copy: { _ in }, save: { _ in }, close: {})), .init(width: 820, height: 560))
                ]
                await render(UIReviewOverview(pages: overview).environment(\.colorScheme, scheme),
                             size: .init(width: 1240, height: 980), name: "overview-\(suffix)", directory: directory)
            }
            // Populate only the isolated library after empty-state rendering.
            let folder = RecordingLibrary.directory.appendingPathComponent("design-fixture")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: video, to: folder.appendingPathComponent("DeskCapture-界面演示.mp4"))
            for (suffix, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                NSApp.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                await render(RecordingLibraryView(app: coordinator).environment(\.colorScheme, scheme),
                             size: .init(width: 720, height: 480), name: "library-filled-\(suffix)", directory: directory)
            }
        }
        print("UI previews: \(directory.path)")
    }

    @MainActor static func render<V: View>(_ view: V, size: CGSize, name: String, directory: URL) async {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(550))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        print("\(name): \(host.bounds.size)")
        window.orderOut(nil)
        window.contentView = nil
        try? await Task.sleep(for: .milliseconds(20))
    }

    static func makeVideo(_ image: CGImage, directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = directory.appendingPathComponent("fixture.mp4")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 400])
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 400])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CaptureError.message("无法建立演示视频") }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<30 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 640, 400, kCVPixelFormatType_32BGRA, nil, &buffer)
                guard let buffer else { throw CaptureError.message("无法生成演示画面") }
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 400, bitsPerComponent: 8,
                                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                context.draw(image, in: .init(x: 0, y: 0, width: 640, height: 400))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error ?? CaptureError.message("演示视频写入失败") }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CaptureError.message("演示视频未完成") }
            try FileManager.default.copyItem(at: url, to: RecordingCamera.url(for: url))
            return url
        }.value
    }

    static func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor); context.fill(.init(x: 0, y: 0, width: 960, height: 600))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(.init(x: 48, y: 48, width: 12, height: 504))
        for row in 0..<5 {
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12 + Double(row) * 0.08).cgColor)
            context.fill(.init(x: 100, y: 90 + row * 90, width: 720 - row * 65, height: 48))
        }
        return context.makeImage()!
    }
}

private struct UIReviewOverview: View {
    let pages: [(String, AnyView, CGSize)]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("DeskCapture · 当前界面总览").font(.system(size: 24, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                ForEach(pages.indices, id: \.self) { index in
                    let page = pages[index]
                    VStack(alignment: .leading, spacing: 10) {
                        Text(page.0).font(.system(size: 14, weight: .semibold))
                        page.1.frame(width: page.2.width, height: page.2.height)
                            .scaleEffect(0.70)
                            .frame(width: 580, height: 394)
                            .clipped()
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.separator))
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(30).frame(width: 1240, height: 980, alignment: .topLeading)
            .foregroundStyle(Palette.white).background(Palette.ink)
    }
}

private struct UIReviewGallery: View {
    let pages: [(String, AnyView)]
    @State private var selection = 0
    @State private var dark = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("深色", isOn: $dark).padding(12)
                List(selection: $selection) {
                    ForEach(pages.indices, id: \.self) { index in Text(pages[index].0).tag(index) }
                }.listStyle(.sidebar)
            }.frame(width: 180)
            Divider()
            pages[selection].1.id(selection).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.preferredColorScheme(dark ? .dark : .light)
    }
}

@MainActor private final class UILayoutPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await UILayoutPreview.runPreview() }
            catch { print("UI preview failed: \(error)"); NSApp.terminate(nil) }
            if !CommandLine.arguments.contains("--interactive") && ProcessInfo.processInfo.environment["DESKCAPTURE_UI_INTERACTIVE"] != "1" {
                NSApp.terminate(nil)
            }
        }
    }
}
