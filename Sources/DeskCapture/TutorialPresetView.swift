import SwiftUI
import UniformTypeIdentifiers

struct TutorialPresetView: View {
    @ObservedObject var document: AnnotationDocument
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TutorialPreset(name: L10n.text("教程预设"))
    @State private var presets: [TutorialPreset] = []
    @State private var legacy: [BeautifyPreset] = []
    @State private var colors = ""
    @State private var result: CGImage?
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var rendering = true
    @State private var backgroundRevision = UUID()
    @State private var operation: Task<Void, Never>?
    private var oldDirectory: URL {
        if let diagnostic = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] { return URL(fileURLWithPath: diagnostic).appendingPathComponent("legacy-beautify-presets") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskCapture/BeautifyPresets")
    }
    private var renderKey: String { "\(draft.backgroundStyle.rawValue):\(draft.layout.rawValue):\(draft.padding):\(draft.roundness):\(backgroundRevision):\(document.renderRevision)" }
    var body: some View {
        StudioWorkspace(title: L10n.text("品牌与教程预设"), symbol: "swatchpalette") {
            StudioMenu(L10n.text("预设库")) {
                ForEach(presets) { preset in Button(preset.name) { load(preset) } }
                Divider()
                Button(L10n.text("导入预设…")) { importPreset() }
                Button(L10n.text("导出预设…")) { exportPreset() }
                if !legacy.isEmpty {
                    Menu(L10n.text("旧版预设")) {
                        ForEach(legacy) { preset in
                            Button(preset.name) {
                                let directory = oldDirectory
                                run { let converted = try await TutorialPresetLibrary.shared.importLegacy(preset, from: directory); load(converted) }
                            }
                        }
                    }
                }
                if !presets.isEmpty {
                    StudioMenu(L10n.text("移除预设")) {
                        ForEach(presets) { preset in Button(preset.name) { run { try await TutorialPresetLibrary.shared.remove(preset.id) } } }
                    }
                }
            }.disabled(busy)
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark") { dismiss() }
        } preview: {
            if let result { Image(decorative: result, scale: 1).resizable().scaledToFit() }
            else if rendering { ProgressView(L10n.text("正在生成预览…")) }
        } inspector: {
            InspectorGroup(L10n.text("预设"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("预设名称")) { TextField(L10n.text("名称"), text: $draft.name) }
                Button(L10n.text("存入预设库")) {
                    guard let value = snapshot() else { return }
                    run { try await TutorialPresetLibrary.shared.save(value); notice = L10n.text("预设已保存") }
                }
            }.disabled(busy)
            InspectorGroup(L10n.text("画布"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("比例")) { Picker(L10n.text("比例"), selection: $draft.layout) { ForEach(BeautifyLayout.allCases) { Text($0.title).tag($0) } }.labelsHidden() }.pickerStyle(.menu).labelsHidden()
                BackgroundSwatches(selection: $draft.backgroundStyle)
                InspectorSlider(title: L10n.text("留白"), value: $draft.padding, range: 0...0.6, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("圆角"), value: $draft.roundness, range: 0...1, scale: 100, unit: "%")
                HStack {
                    Button(L10n.text("导入背景…")) { chooseBackground() }
                    if draft.backgroundPNG != nil { Button(L10n.text("移除背景")) { draft.backgroundPNG = nil; backgroundRevision = UUID() } }
                }
            }.disabled(busy)
            InspectorGroup(L10n.text("色板与标注")) {
                InspectorField(title: L10n.text("色板 HEX")) { TextField(L10n.text("逗号分隔"), text: $colors) }
                Button(L10n.text("记录当前标注样式")) { draft.annotation = SavedAnnotationStyle(name: String(draft.name.prefix(40)), tool: document.tool, document: document) }
                if let style = draft.annotation { Text(L10n.text("\(style.tool.title) · \(Int(style.fontSize)) pt")).foregroundStyle(Palette.muted) }
            }.disabled(busy)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let notice { Text(notice).foregroundStyle(Palette.muted) }
        } actions: {
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(L10n.text("保存图片…")) { savePreview() }.disabled(busy || rendering || result == nil)
            Button(L10n.text("应用预设")) { apply() }.disabled(busy).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task {
                if let existing = document.tutorialPreset { load(existing) }
                else {
                    draft.annotation = SavedAnnotationStyle(name: L10n.text("当前标注"), tool: document.tool, document: document)
                    colors = AnnotationPresetStore.shared.colors.joined(separator: ", ")
                }
                do {
                    presets = try await TutorialPresetLibrary.shared.list()
                    legacy = try await TutorialPresetLibrary.shared.legacyPresets(in: oldDirectory)
                } catch { self.error = error.localizedDescription }
            }
            .task(id: renderKey) {
                rendering = true; result = nil
                document.commitPendingText?()
                let source = document.original, marks = document.marks, preset = draft
                let worker = Task.detached {
                    let copy = AnnotationDocument(image: source); copy.marks = marks
                    guard let image = copy.render() else { throw CaptureError.message(L10n.text("画面渲染失败。")) }
                    return try preset.render(image)
                }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }; result = value; rendering = false
                } catch { if !Task.isCancelled { rendering = false; self.error = error.localizedDescription } }
            }
            .onDisappear { operation?.cancel() }
    }
    private func load(_ preset: TutorialPreset) { draft = preset; colors = preset.palette.joined(separator: ", "); backgroundRevision = UUID(); error = nil }
    private func snapshot() -> TutorialPreset? {
        var value = draft
        value.palette = colors.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map(String.init)
        if value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.name.count > 40 || value.palette.count > 12 || !value.palette.allSatisfy({ CaptureColorAnalysis.parse($0) != nil }) {
            error = L10n.text("名称需1–40字；色板最多12个六位HEX颜色。"); return nil
        }
        return value
    }
    private func apply() {
        guard let value = snapshot() else { return }
        value.annotation?.apply(to: document)
        AnnotationPresetStore.shared.replacePalette(value.palette.map { $0.hasPrefix("#") ? $0 : "#" + $0 })
        document.tutorialPreset = value
        notice = L10n.text("已应用下一笔样式与色板；画布配置随工程保留。")
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        operation = Task {
            defer { busy = false }
            do { try await work(); try Task.checkCancellation(); presets = try await TutorialPresetLibrary.shared.list() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func importPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "deskpreset") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { let preset = try await TutorialPresetLibrary.shared.importFile(url); load(preset) }
    }
    private func exportPreset() {
        guard let value = snapshot() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("教程预设.deskpreset")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await presetBackground { try TutorialPresetLibrary.export(value, to: url) }; notice = L10n.text("已导出预设，不包含当前截图。") }
    }
    private func chooseBackground() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run {
            let value = try await presetBackground { try TutorialPreset.backgroundData(CaptureImageRead.load(url)) }
            try Task.checkCancellation(); draft.backgroundPNG = value; backgroundRevision = UUID()
        }
    }
    private func savePreview() {
        guard let image = result else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = L10n.text("教程截图.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await presetBackground { try CaptureImageExport.png(image, to: url) }; notice = L10n.text("已保存带背景的预览副本。") }
    }
}

private func presetBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
    return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
}
