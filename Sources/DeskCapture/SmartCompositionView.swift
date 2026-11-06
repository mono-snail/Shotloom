import SwiftUI

struct SmartCompositionView: View {
    let image: CGImage
    let save: (CGImage) -> Void
    let close: () -> Void
    @State private var analysis: CompositionAnalysis?
    @State private var focus = CGPoint(x: 0.5, y: 0.5)
    @State private var locked = false
    @State private var layout = BeautifyLayout.landscape
    @State private var style = BeautifyStyle.frost
    @State private var padding = 0.15
    @State private var result: CGImage?
    @State private var completedRequest: String?
    @State private var error: String?
    @State private var analysisError: String?
    @State private var analysisRequest = UUID()
    @State private var analysisPending = true
    @State private var busy = true
    private var request: String { "\(layout.rawValue):\(style.rawValue):\(padding):\(focus.x):\(focus.y)" }
    private var currentResult: CGImage? { completedRequest == request ? result : nil }
    var body: some View {
        StudioWorkspace(title: L10n.text("智能构图"), symbol: "viewfinder") {
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark", action: close)
        } preview: {
            Image(decorative: currentResult ?? image, scale: 1).resizable().scaledToFit()
        } inspector: {
            InspectorGroup(L10n.text("画布"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("比例")) { Picker(L10n.text("比例"), selection: $layout) { ForEach(BeautifyLayout.allCases) { Text($0.title).tag($0) } }.labelsHidden() }.pickerStyle(.menu).labelsHidden()
                BackgroundSwatches(selection: $style)
                InspectorSlider(title: L10n.text("留白"), value: $padding, range: 0...0.6, scale: 100, unit: "%")
            }
            InspectorGroup(L10n.text("画面位置"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("定位")) { Picker(L10n.text("定位"), selection: $locked) { Text(L10n.text("自动")).tag(false); Text(L10n.text("手动")).tag(true) }.labelsHidden() }
                    .pickerStyle(.segmented).labelsHidden()
                    .onChange(of: locked) { _, value in if !value { focus = analysis?.focus ?? .init(x: 0.5, y: 0.5) } }
                if locked {
                    InspectorSlider(title: L10n.text("水平位置"), value: Binding(get: { focus.x }, set: { focus.x = $0; locked = true }), range: 0...1, scale: 100, unit: "%")
                    InspectorSlider(title: L10n.text("垂直位置"), value: Binding(get: { focus.y }, set: { focus.y = $0; locked = true }), range: 0...1, scale: 100, unit: "%")
                    Button(L10n.text("居中")) { focus = .init(x: 0.5, y: 0.5) }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let analysisError {
                StudioMessage(text: analysisError, kind: .warning)
                Button(L10n.text("重试")) { analysisRequest = UUID() }
            }
        } actions: {
            if busy || analysisPending { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("智能构图")) }
            Spacer()
            Button(L10n.text("保存副本…")) { if let result = currentResult { save(result) } }.disabled(busy || currentResult == nil || (!locked && analysisPending)).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task(id: analysisRequest) {
                let token = analysisRequest
                analysisError = nil; analysisPending = true
                defer { if token == analysisRequest { analysisPending = false } }
                let worker = Task.detached { try SmartComposition.analyze(image) }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, token == analysisRequest else { return }; analysis = value
                    if !locked { focus = value.focus }
                } catch { if !Task.isCancelled, token == analysisRequest { analysisError = error.localizedDescription } }
            }
            .task(id: request) {
                busy = true; result = nil; error = nil
                let token = request
                let style = style, padding = padding, layout = layout, focus = focus
                let worker = Task.detached {
                    try Task.checkCancellation()
                    return try CaptureBeautifier.render(image, style: style, paddingPercent: padding, roundness: 0, layout: layout, contentFocus: focus)
                }
                do {
                    let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, token == request else { return }; result = value; completedRequest = token; busy = false
                } catch { if !Task.isCancelled, token == request { self.error = error.localizedDescription; busy = false } }
            }
    }
}
