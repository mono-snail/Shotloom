import SwiftUI

struct SpeakerNotesEditor: View {
    @ObservedObject var controller: SpeakerNotesController
    @State private var fileTask: Task<Void, Never>?
    @State private var fileError: String?
    var body: some View {
        StudioWorkspace(title: L10n.text("录制提词稿"), symbol: "text.alignleft") {
            Button(L10n.text("导入 TXT…")) { importText() }
        } preview: {
            TextEditor(text: $controller.text).font(.system(size: 15))
                .scrollContentBackground(.hidden).padding(12)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(L10n.text("提词稿正文"))
        } inspector: {
            InspectorGroup(L10n.text("提词器"), initiallyExpanded: true) {
                Toggle(L10n.text("录制时显示"), isOn: $controller.enabled)
                if controller.enabled {
                    Toggle(L10n.text("自动滚动"), isOn: $controller.scrolling)
                    if controller.scrolling {
                        InspectorSlider(title: L10n.text("滚动速度"), value: $controller.options.speed, range: 4...100, unit: " pt/s")
                    }
                    Button(L10n.text("回到开头")) { controller.rewind() }
                }
            }
            if controller.enabled {
                InspectorGroup(L10n.text("显示"), initiallyExpanded: true) {
                    InspectorSlider(title: L10n.text("字号"), value: $controller.options.fontSize, range: 16...64, unit: " pt")
                    InspectorSlider(title: L10n.text("透明度"), value: $controller.options.opacity, range: 0.3...1, scale: 100, unit: "%")
                    InspectorField(title: L10n.text("位置")) {
                        Picker(L10n.text("位置"), selection: $controller.options.bottom) { Text(L10n.text("屏幕上方")).tag(false); Text(L10n.text("屏幕下方")).tag(true) }
                    }
                }
                InspectorGroup(L10n.text("尺寸")) {
                    InspectorSlider(title: L10n.text("宽度"), value: $controller.options.width, range: 320...1000, unit: " pt")
                    InspectorSlider(title: L10n.text("高度"), value: $controller.options.height, range: 140...500, unit: " pt")
                }
            }
            if let error = controller.error ?? fileError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            Spacer()
            Button(L10n.text("导出提词稿…")) { exportText() }.buttonStyle(StudioButtonStyle(primary: true, command: true))
        }.onDisappear { fileTask?.cancel() }
    }
    private func importText() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileTask?.cancel(); fileError = nil
        fileTask = Task {
            let worker = Task.detached {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65_536 else { throw CaptureError.message(L10n.text("讲稿最多64KB。")) }
                guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw CaptureError.message(L10n.text("请选择UTF-8文本文件。")) }; return text
            }
            do {
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; controller.text = text
            } catch { if !Task.isCancelled { fileError = error.localizedDescription } }
        }
    }
    private func exportText() {
        let text = controller.text, panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = L10n.text("提词稿.txt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileTask?.cancel(); fileError = nil
        fileTask = Task {
            let worker = Task.detached {
                let data = Data(text.utf8)
                guard data.count <= 65_536 else { throw CaptureError.message(L10n.text("讲稿超过64KB，请先拆分。")) }
                try Task.checkCancellation(); try data.write(to: url, options: .atomic)
            }
            do { try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }) }
            catch { if !Task.isCancelled { fileError = error.localizedDescription } }
        }
    }
}

struct SpeakerNotesControls: View {
    @ObservedObject var controller: SpeakerNotesController
    var body: some View {
        Menu {
            Toggle(L10n.text("显示提词器"), isOn: $controller.enabled)
            Toggle(L10n.text("自动滚动"), isOn: $controller.scrolling)
            Button(L10n.text("回到开头")) { controller.rewind() }
            Button(L10n.text("编辑稿件与显示设置…")) { controller.showEditor() }
            if let error = controller.error { Text(error) }
        } label: { Image(systemName: "text.alignleft").frame(width: 18) }
            .menuStyle(.borderlessButton).fixedSize().help(L10n.text("录制提词器"))
    }
}
