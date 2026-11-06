import SwiftUI

struct LocalWorkflowReviewInput: Identifiable {
    let id = UUID()
    let image: CGImage
    let candidates: [SensitiveReviewCandidate]
}
enum LocalWorkflowSensitive {
    static func scan(_ image: CGImage, rules: [SensitiveRule]) async throws -> [SensitiveReviewCandidate] {
        let lines = try await CaptureEngine.recognizeLines(image)
        try Task.checkCancellation()
        return try SensitiveRuleEvaluation.classify(lines, kinds: Set(SensitiveKind.allCases), rules: rules, scope: .images)
    }
}

/// The sheet only returns chosen bounds. Flattening and the remaining workflow
/// execute in the processor's worker after explicit confirmation.
struct WorkflowSensitiveReviewView: View {
    let input: LocalWorkflowReviewInput
    let cancel: () -> Void
    let confirm: ([CGRect]) -> Void
    @State private var selected: Set<UUID>
    @State private var manual: [CGRect] = []
    @State private var reviewed = false
    @State private var preview: CGImage?
    @State private var rendering = true
    @State private var error: String?
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    init(input: LocalWorkflowReviewInput, cancel: @escaping () -> Void, confirm: @escaping ([CGRect]) -> Void) {
        self.input = input; self.cancel = cancel; self.confirm = confirm
        _selected = State(initialValue: Set(input.candidates.map(\.id)))
    }
    private var bounds: [CGRect] { input.candidates.filter { selected.contains($0.id) }.map(\.line.bounds) + manual }
    private struct PreviewKey: Equatable { let selected: Set<UUID>; let manual: [CGRect] }
    @State private var renderedKey: PreviewKey?
    private var previewKey: PreviewKey { PreviewKey(selected: selected, manual: manual) }
    private var previewReady: Bool { !rendering && error == nil && renderedKey == previewKey }
    var body: some View {
        StudioWorkspace(title: L10n.text("敏感信息复核"), symbol: "lock.shield") {
            Button(L10n.text("取消流程"), action: cancel)
        } preview: {
                GeometryReader { geometry in
                    if let preview {
                        let scale = min(geometry.size.width / CGFloat(preview.width), geometry.size.height / CGFloat(preview.height))
                        let size = CGSize(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                        Image(decorative: preview, scale: 1).resizable().frame(width: size.width, height: size.height)
                            .overlay {
                                if let dragStart, let dragEnd {
                                    Rectangle().stroke(.red, lineWidth: 2)
                                        .frame(width: abs(dragEnd.x - dragStart.x), height: abs(dragEnd.y - dragStart.y))
                                        .position(x: (dragStart.x + dragEnd.x) / 2, y: (dragStart.y + dragEnd.y) / 2)
                                }
                            }
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                dragStart = value.startLocation; dragEnd = value.location
                            }.onEnded { value in
                                defer { dragStart = nil; dragEnd = nil }
                                guard previewReady, manual.count < 256, size.width > 0, size.height > 0 else { return }
                                let a = value.startLocation, b = value.location
                                let rect = CGRect(x: min(a.x, b.x) / size.width, y: 1 - max(a.y, b.y) / size.height,
                                                  width: abs(a.x - b.x) / size.width, height: abs(a.y - b.y) / size.height)
                                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                                if !rect.isEmpty { reviewed = false; manual.append(rect) }
                            })
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    } else { ProgressView(L10n.text("准备遮盖预览…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
        } inspector: {
            InspectorGroup(L10n.text("识别候选"), initiallyExpanded: true) {

                    Text(L10n.text("候选 \(input.candidates.count) 行")).fontWeight(.medium)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(input.candidates) { candidate in
                                Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { enabled in
                                    reviewed = false
                                    if enabled { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                                })) {
                                    VStack(alignment: .leading) {
                                        Text(candidate.line.text).lineLimit(3)
                                        Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                                        if !candidate.line.alternatives.isEmpty { Text(candidate.line.alternatives.joined(separator: " / ")).font(.caption).lineLimit(3) }
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }
                    }.frame(minHeight: 120, maxHeight: 300)
                    Button(L10n.text("撤销最近框选（\(manual.count)）")) { reviewed = false; _ = manual.popLast() }.disabled(manual.isEmpty)
                    Toggle(L10n.text("已人工复核当前遮盖预览"), isOn: $reviewed).toggleStyle(.checkbox).disabled(!previewReady)

            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            if rendering { ProgressView().controlSize(.small) }
            Spacer()
            Button(L10n.text("确认遮盖并继续")) { if reviewed && previewReady { confirm(bounds) } }
                .disabled(!reviewed || !previewReady).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task(id: previewKey) {
                rendering = true; error = nil; reviewed = false
                let source = input.image, rects = bounds, key = previewKey
                let worker = Task.detached { try SensitiveBatchIO.flattened(source, bounds: rects) }
                do {
                    let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }; preview = image; renderedKey = key; rendering = false
                } catch { if !Task.isCancelled { rendering = false; self.error = error.localizedDescription } }
            }
    }
}
