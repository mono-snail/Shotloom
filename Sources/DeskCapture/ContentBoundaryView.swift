import SwiftUI

struct ContentBoundaryView: View {
    @ObservedObject var document: AnnotationDocument
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var candidates: [ContentBoundary] = []
    @State private var selected: CGRect?
    @State private var revision: Int?
    @State private var scale = 1.0
    @State private var snapping = true
    @State private var busy = true
    @State private var error: String?
    @State private var drag: CGRect?
    @State private var analysisRequest = UUID()
    private var validScale: Bool { scale.isFinite && (0.5...8).contains(scale) }
    private var canApply: Bool { !busy && selected?.isEmpty == false && revision == document.renderRevision }
    var body: some View {
        StudioWorkspace(title: L10n.text("内容边界与尺寸"), symbol: "rectangle.dashed") {
            Button(L10n.text("重新识别")) { analysisRequest = UUID() }.disabled(busy)
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark") { dismiss() }
        } preview: {
            GeometryReader { geometry in
                if let image {
                    let factor = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) {
                            ForEach(candidates) { candidate in
                                let box = candidate.bounds
                                Rectangle().stroke(Palette.ice.opacity(0.25), lineWidth: 1)
                                    .frame(width: box.width * size.width, height: box.height * size.height)
                                    .offset(x: box.minX * size.width, y: (1 - box.maxY) * size.height)
                            }
                            if let box = drag ?? selected {
                                Rectangle().stroke(Palette.ice, lineWidth: 2)
                                    .frame(width: box.width * size.width, height: box.height * size.height)
                                    .offset(x: box.minX * size.width, y: (1 - box.maxY) * size.height)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            drag = rectangle(value, size: size)
                        }.onEnded { value in
                            defer { drag = nil }
                            if hypot(value.translation.width, value.translation.height) < 3 {
                                let point = CGPoint(x: value.location.x / size.width, y: 1 - value.location.y / size.height)
                                if let hit = ContentBoundaryEngine.hit(point, candidates: candidates) { selected = hit.bounds; error = nil }
                                else { error = L10n.text("此处没有可信候选，可拖动手动框选。") }
                            } else {
                                let box = rectangle(value, size: size)
                                selected = snapping ? ContentBoundaryEngine.snap(box, candidates: candidates, tolerance: CGSize(width: 6 / size.width, height: 6 / size.height)) : box
                                error = nil
                            }
                        })
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        } inspector: {
            InspectorGroup(L10n.text("选区"), initiallyExpanded: true) {
                Toggle(L10n.text("边界吸附"), isOn: $snapping)
                InspectorField(title: L10n.text("像素与逻辑尺寸比例")) {
                    TextField(L10n.text("比例"), value: $scale, format: .number).accessibilityLabel(L10n.text("像素与逻辑尺寸比例"))
                }
            }
            if !validScale {
                StudioMessage(text: L10n.text("比例需在 0.5–8 之间。"), kind: .warning)
                Button(L10n.text("恢复屏幕比例")) { scale = Double(document.backingScale) }
            }
            if let image, let selected,
               let value = try? ContentBoundaryEngine.dimensions(selected, pixels: CGSize(width: image.width, height: image.height), scale: scale) {
                InspectorGroup(L10n.text("选区尺寸"), initiallyExpanded: true) {
                    LabeledContent(L10n.text("像素"), value: String(format: "%.0f × %.0f px", value.pixels.width, value.pixels.height))
                    LabeledContent(L10n.text("逻辑"), value: String(format: "%.1f × %.1f pt", value.logical.width, value.logical.height))
                }.textSelection(.enabled).monospacedDigit()
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let revision, revision != document.renderRevision, !busy, error == nil {
                StudioMessage(text: L10n.text("画面已改变，请重新识别。"), kind: .warning)
            }
        } actions: {
            if busy { ProgressView(L10n.text("正在分析当前画面…")).controlSize(.small) }
            Spacer()
            Button(L10n.text("标记选区")) { apply(.rectangle) }.disabled(!canApply)
            Button(L10n.text("遮盖选区")) { apply(.redact) }.disabled(!canApply).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task(id: analysisRequest) {
                let token = analysisRequest
                busy = true; error = nil; selected = nil; candidates = []; image = nil
                document.commitPendingText?()
                let original = document.original, marks = document.marks, expected = document.renderRevision
                if revision == nil { scale = Double(document.backingScale) }
                let worker = Task.detached { () throws -> (CGImage, [ContentBoundary]) in
                    let snapshot = AnnotationDocument(image: original); snapshot.marks = marks
                    guard let image = snapshot.render() else { throw CaptureError.message(L10n.text("当前画面无法渲染。")) }
                    return (image, try await ContentBoundaryEngine.detect(image))
                }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, token == analysisRequest else { return }
                    guard expected == document.renderRevision else {
                        busy = false; error = L10n.text("画面已改变，请重新识别。"); return
                    }
                    image = value.0; candidates = value.1; revision = expected; busy = false
                } catch { if !Task.isCancelled, token == analysisRequest { busy = false; self.error = error.localizedDescription } }
            }
    }
    private func rectangle(_ value: DragGesture.Value, size: CGSize) -> CGRect {
        CGRect(x: min(value.startLocation.x, value.location.x) / size.width,
               y: 1 - max(value.startLocation.y, value.location.y) / size.height,
               width: abs(value.translation.width) / size.width, height: abs(value.translation.height) / size.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    private func apply(_ tool: AnnotationTool) {
        guard let selected, !selected.isEmpty else { return }
        guard revision == document.renderRevision else { error = L10n.text("画面已改变，请重新识别。"); return }
        document.add(document.makeMark(tool: tool, points: [.init(x: selected.minX, y: selected.minY), .init(x: selected.maxX, y: selected.maxY)]))
        dismiss()
    }
}
