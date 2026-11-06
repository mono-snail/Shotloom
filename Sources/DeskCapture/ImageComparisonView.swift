import SwiftUI

struct ImageComparisonView: View {
    @ObservedObject var document: AnnotationDocument
    @Environment(\.dismiss) private var dismiss
    @State private var after: CGImage?
    @State private var settings = ImageComparisonSettings()
    @State private var result: ImageComparisonResult?
    @State private var completedRenderKey: String?
    @State private var expected: ImageComparisonReport?
    @State private var imageRevision = UUID()
    @State private var sourceRequest = UUID()
    @State private var zoom = 0.35
    @State private var focus: Int?
    @State private var showRegions = true
    @State private var busy = false
    @State private var exporting = false
    @State private var lastExportedURL: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private var key: String { "\(settings.mode.rawValue):\(settings.split):\(settings.opacity):\(settings.scale):\(settings.offsetX):\(settings.offsetY):\(settings.threshold):\(imageRevision)" }
    private var currentResult: ImageComparisonResult? { completedRenderKey == key ? result : nil }
    var body: some View {
        StudioWorkspace(title: L10n.text("图片对照"), symbol: "rectangle.on.rectangle") {
            Button(L10n.text("载入图片…")) { chooseAfter() }.disabled(exporting)
            StudioMenu(L10n.text("设置文件")) {
                Button(L10n.text("载入设置…")) { openSettings() }.disabled(exporting)
                Button(L10n.text("导出设置与测量…")) { exportReport() }.disabled(busy || exporting || currentResult == nil)
            }
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark") { dismiss() }
        } preview: {
                ScrollViewReader { reader in
                    ScrollView([.horizontal, .vertical]) {
                        if let result = currentResult {
                            Image(decorative: result.image, scale: 1).resizable()
                                .frame(width: CGFloat(result.image.width) * zoom, height: CGFloat(result.image.height) * zoom)
                                .overlay(alignment: .topLeading) {
                                    if showRegions && settings.mode == .difference {
                                        ForEach(Array(result.regions.enumerated()), id: \.offset) { index, box in
                                            Rectangle().stroke(index == focus ? .yellow : .cyan, lineWidth: index == focus ? 3 : 1)
                                                .frame(width: box.width * zoom, height: box.height * zoom)
                                                .offset(x: box.minX * zoom, y: box.minY * zoom).id(index)
                                        }
                                    }
                                }
                        } else { Text(busy ? L10n.text("正在计算对照…") : L10n.text("准备图片…")).frame(width: 430, height: 320) }
                    }.onChange(of: focus) { _, value in if let value { reader.scrollTo(value, anchor: .center) } }
                        .onChange(of: currentResult?.report.settings.mode) { _, _ in if let focus { reader.scrollTo(focus, anchor: .center) } }
                }
        } inspector: {
            VStack(alignment: .leading, spacing: 16) {
                InspectorGroup(L10n.text("对照方式"), initiallyExpanded: true) {
                    InspectorField(title: L10n.text("方式")) { Picker(L10n.text("方式"), selection: $settings.mode) { ForEach(ImageComparisonSettings.Mode.allCases) { Text($0.title).tag($0) } }.labelsHidden() }.labelsHidden()
                    if settings.mode == .wipe { InspectorSlider(title: L10n.text("原图占比"), value: $settings.split, range: 0...1, scale: 100, unit: "%") }
                    if settings.mode == .blend { InspectorSlider(title: L10n.text("叠层透明度"), value: $settings.opacity, range: 0...1, scale: 100, unit: "%") }
                }
                InspectorGroup(L10n.text("图片对齐")) {
                    InspectorSlider(title: L10n.text("叠层缩放"), value: $settings.scale, range: 0.25...4, unit: "×", decimals: 2)
                    InspectorField(title: L10n.text("水平偏移（px）")) { TextField(L10n.text("像素"), value: $settings.offsetX, format: .number) }
                    InspectorField(title: L10n.text("垂直偏移（px）")) { TextField(L10n.text("像素"), value: $settings.offsetY, format: .number) }
                    Button(L10n.text("重置对齐")) { settings.scale = 1; settings.offsetX = 0; settings.offsetY = 0 }
                }
                if settings.mode == .difference {
                    InspectorGroup(L10n.text("差异区域"), initiallyExpanded: true) {
                        Stepper(L10n.text("识别阈值 \(settings.threshold)"), value: $settings.threshold, in: 0...255)
                        Toggle(L10n.text("显示区域边框"), isOn: $showRegions)
                        if let report = currentResult?.report {
                            LabeledContent(L10n.text("变化像素"), value: "\(report.changedPixels)")
                            LabeledContent(L10n.text("差异区域"), value: "\(report.regionCount)")
                        }
                        if let result = currentResult {
                            ForEach(Array(result.regions.enumerated()), id: \.offset) { index, box in
                                Button(L10n.text("\(index + 1) · \(Int(box.width)) × \(Int(box.height)) px")) { focus = index }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let expected, let report = currentResult?.report,
                   expected.alignedBeforeSHA256 != report.alignedBeforeSHA256 || expected.alignedAfterSHA256 != report.alignedAfterSHA256 {
                    Label(L10n.text("图片与载入记录不一致"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }.disabled(exporting)
        } actions: {
            Text(L10n.text("视图"))
            Slider(value: $zoom, in: 0.1...3).frame(width: 120).accessibilityLabel(L10n.text("视图缩放"))
            Text("\(Int(zoom * 100))%").monospacedDigit()
            if busy || exporting { ProgressView().controlSize(.small) }
            Spacer()
            if let lastExportedURL { StudioExportReceipt(url: lastExportedURL) }
            Button(L10n.text("导出对照图…")) { exportImage() }.disabled(busy || exporting || currentResult == nil).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task {
                document.commitPendingText?()
                let original = document.original, marks = document.marks, revision = document.renderRevision, request = sourceRequest
                let worker = Task.detached { () throws -> CGImage in
                    let snapshot = AnnotationDocument(image: original); snapshot.marks = marks
                    guard let image = snapshot.render() else { throw CaptureError.message(L10n.text("当前画面无法渲染。")) }; return image
                }
                do {
                    let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, revision == document.renderRevision, request == sourceRequest else { return }; after = image; imageRevision = UUID()
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .task(id: key) {
                guard let after else { return }
                busy = true; result = nil; error = nil
                let request = key
                let before = document.original, settings = settings
                let worker = Task.detached { try ImageComparison.render(before: before, after: after, settings: settings) }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, request == key else { return }; result = value; completedRenderKey = request; busy = false
                } catch { if !Task.isCancelled, request == key { busy = false; self.error = error.localizedDescription } }
            }
            .onDisappear { task?.cancel() }
    }
    private func run<T>(_ work: @escaping () throws -> T, apply: @escaping (T) -> Void) {
        guard !exporting else { return }; exporting = true; error = nil
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
            defer { exporting = false }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; apply(value)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func chooseAfter() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceRequest = UUID()
        run({ try SensitiveBatchIO.read(url) }) { after = $0; imageRevision = UUID(); focus = nil }
    }
    private func openSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run({
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_384 else { throw CaptureError.message(L10n.text("对照设置超过16KB。")) }
            return try ImageComparisonReport.decode(Data(contentsOf: url))
        }) { expected = $0; settings = $0.settings }
    }
    private func exportReport() {
        guard let report = currentResult?.report else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = L10n.text("图片对照设置.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run({ let data = try JSONEncoder().encode(report); try Task.checkCancellation(); try data.write(to: url, options: .atomic) }) { _ in lastExportedURL = url }
    }
    private func exportImage() {
        guard let image = currentResult?.image else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = L10n.text("图片对照.png")
        panel.message = L10n.text("滑动、叠加和并排模式包含工程原图。请确认原图适合分享。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run({ try ImageComparison.exportPNG(image, to: url) }) { _ in lastExportedURL = url }
    }
}
