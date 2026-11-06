import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AnnotationDocument {
    @MainActor func importOverlay(completion: @escaping () -> Void = {}) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if let window = NSApp.keyWindow { panel.level = window.level }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(); return }
            let revision = self.renderRevision, owner = self.presentationWindow
            Task { @MainActor in
                do {
                    let image = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
                              Double(w) * Double(h) <= 20_000_000,
                              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                            throw CaptureError.message(L10n.text("图片无法读取，或超过 2000 万像素叠层上限。"))
                        }
                        return image
                    }.value
                    guard revision == self.renderRevision, owner?.isVisible != false else { self.reportPixelPreparationError(L10n.text("画面已改变或窗口已关闭，未添加旧叠层。")); completion(); return }
                    self.addImageOnCanvas(image); await self.waitForCanvasPixels(); completion()
                } catch {
                    let alert = NSAlert(); alert.messageText = L10n.text("无法添加图片"); alert.informativeText = error.localizedDescription
                    alert.window.level = panel.level; alert.runModal(); completion()
                }
            }
        }
    }
    @MainActor func exportComparison() {
        renderForDelivery { [weak self] edited in self?.exportComparisonSnapshot(edited) }
    }
    @MainActor private func exportComparisonSnapshot(_ edited: CGImage) {
        let source = original
        let panel = NSSavePanel(); panel.allowedContentTypes = [.gif]
        if let window = NSApp.keyWindow { panel.level = window.level }
        panel.nameFieldStringValue = L10n.text("DeskCapture 前后对照.gif")
        panel.message = L10n.text("第一帧包含原图，第二帧包含当前编辑结果。请确认原图可用于对照。")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try CaptureComparisonExporter.gif(before: source, after: edited, to: url)
                    }.value
                } catch {
                    let alert = NSAlert(); alert.messageText = L10n.text("对照导出失败"); alert.informativeText = error.localizedDescription; alert.runModal()
                }
            }
        }
    }
}

enum CaptureComparisonExporter {
    static func gif(before: CGImage, after: CGImage, to url: URL) throws {
        guard before.width == after.width, before.height == after.height else { throw CaptureError.message(L10n.text("对照图片尺寸不一致。")) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil) else {
            throw CaptureError.message(L10n.text("无法创建对照 GIF。"))
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in [before, after] {
            let scale = min(1, 1600 / Double(max(image.width, image.height)))
            let frame = try CaptureImageTransform.render(image, width: max(1, Int(Double(image.width) * scale)),
                                                         height: max(1, Int(Double(image.height) * scale)))
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.8]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message(L10n.text("GIF 编码失败。")) }
        try (data as Data).write(to: url, options: .atomic)
    }
}

struct InlineOCRRewriteView: View {
    @ObservedObject var document: AnnotationDocument
    let done: () -> Void
    @State private var replacements: [UUID: String] = [:]
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(L10n.text("改写原图文字")).font(.system(size: 12, weight: .semibold)); Spacer(); Button(L10n.text("完成"), action: done) }
            InspectorField(title: L10n.text("背景修复")) {
                Picker(L10n.text("背景修复"), selection: $document.repairMode) { Text(L10n.text("平滑")).tag(RepairMode.smooth); Text(L10n.text("纹理")).tag(RepairMode.texture) }.pickerStyle(.segmented)
            }
            InspectorField(title: L10n.text("替换字体")) { Menu(document.fontName.isEmpty ? L10n.text("系统字体") : document.fontName) {
                Button(L10n.text("系统字体")) { document.fontName = "" }
                ForEach(["PingFangSC-Regular", "PingFangSC-Semibold", "HelveticaNeue", "HelveticaNeue-Bold", "Menlo-Regular", "Georgia"], id: \.self) { name in Button(name) { document.fontName = name } }
            } }
            if loading { ProgressView(L10n.text("正在识别…")) }
            if document.replacingOCR { HStack { ProgressView(L10n.text("正在重建文字背景…")); Button(L10n.text("取消")) { document.cancelOCRReplacement() } } }
            if let error = document.ocrReplacementError { Text(error).foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(document.ocrLines) { line in
                        HStack {
                            if line.needsReview { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(L10n.text("识别信心较低或语言结果存在分歧，请对照原图")) }
                            TextField(line.text, text: Binding(get: { replacements[line.id] ?? line.text }, set: { replacements[line.id] = $0 }))
                            OCRFontFittingButton(document: document, line: line, text: replacements[line.id] ?? line.text)
                            if !line.alternatives.isEmpty {
                                Menu(L10n.text("候选")) {
                                    ForEach([line.text] + line.alternatives, id: \.self) { candidate in Button(candidate) { replacements[line.id] = candidate } }
                                }.fixedSize()
                            }
                            Button(L10n.text("替换")) { Task { await document.replaceOCRLine(line, with: replacements[line.id] ?? line.text) } }.disabled(document.replacingOCR)
                        }
                    }
                }
            }.frame(maxHeight: 220)
        }.font(.system(size: 13)).textFieldStyle(.roundedBorder).controlSize(.small).padding(20).frame(width: 440)
            .onDisappear { document.cancelOCRReplacement() }
            .task {
                defer { loading = false }
                do {
                    let lines = try await CaptureEngine.recognizeLines(document.original)
                    guard !Task.isCancelled else { return }
                    document.ocrLines = lines
                    if document.ocrLines.isEmpty { error = L10n.text("没有识别到文字。") }
                } catch { self.error = error.localizedDescription }
            }
    }
}
