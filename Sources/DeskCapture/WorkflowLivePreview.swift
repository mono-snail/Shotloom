import AppKit
import Combine

struct WorkflowPreviewResult {
    let image: CGImage
    let deferredTools: [String]
}

/// Prefix results are reused when a later tool changes. The cache holds at most
/// 64 MiB of image rows, independent of the number of recipe steps.
/// Rendering uses the very same source-pixel operations as final delivery; only
/// the displayed image is reduced. Preview images never become deliverables.
actor WorkflowPreviewRenderer {
    static let maximumDimension = 1600
    private let byteBudget = 64 * 1024 * 1024
    private var source: CGImage?
    private var steps: [LocalWorkflowStep] = []
    private var frames: [Int: CGImage] = [:]

    func render(_ input: CGImage, steps requested: [LocalWorkflowStep]) throws -> WorkflowPreviewResult {
        try Task.checkCancellation()
        guard input.width > 0, input.height > 0, Double(input.width) * Double(input.height) <= 32_000_000,
              requested.count <= 12 else { throw CaptureError.message(L10n.text("流程预览支持最多3200万像素、12个步骤。")) }
        var deferred: [String] = []
        let visual = requested.filter { step in
            switch step.kind {
            case .ocr, .sensitiveReview: deferred.append(L10n.text("\(step.kind.title)将在运行时执行")); return false
            case .watermark where step.watermark?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true:
                deferred.append(L10n.text("水印待填写文字")); return false
            default: return true
            }
        }
        if !visual.isEmpty {
            var validation = LocalWorkflowRecipe(); validation.steps = visual; validation.output = .init(kind: .preview)
            try validation.validate()
        }
        if source.map(ObjectIdentifier.init) != ObjectIdentifier(input) {
            source = input; steps = []; frames = [:]
        }
        let common = zip(steps, visual).prefix(while: { $0.0 == $0.1 }).count
        frames = frames.filter { $0.key <= common }
        steps = visual
        let start = frames.keys.max() ?? 0
        var result = frames[start] ?? input
        for index in start..<visual.count {
            try Task.checkCancellation()
            result = try LocalWorkflowProcessor.transform(result, step: visual[index])
            let bytes = result.bytesPerRow * result.height
            if bytes <= byteBudget {
                frames[index + 1] = result
                while frames.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > byteBudget,
                      let first = frames.keys.min() { frames.removeValue(forKey: first) }
            }
        }
        try Task.checkCancellation()
        let ratio = min(1, Double(Self.maximumDimension) / Double(max(result.width, result.height)))
        if ratio < 1 {
            result = try CaptureImageTransform.render(result, width: max(1, Int(Double(result.width) * ratio)),
                height: max(1, Int(Double(result.height) * ratio)))
        }
        try Task.checkCancellation()
        let hints = deferred.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return .init(image: result, deferredTools: hints)
    }
}

@MainActor final class WorkflowLivePreview: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var updating = false
    @Published private(set) var isCurrent = false
    @Published private(set) var error: String?
    @Published private(set) var deferredTools: [String] = []
    private let renderer = WorkflowPreviewRenderer()
    private var request = UUID()
    private var task: Task<Void, Never>?
    private var sourceID: ObjectIdentifier?

    func cancel() { if updating { isCurrent = false }; request = UUID(); task?.cancel(); task = nil; updating = false }
    func update(source: CGImage?, steps: [LocalWorkflowStep]) {
        cancel(); error = nil; isCurrent = false
        guard let source else { image = nil; sourceID = nil; deferredTools = []; return }
        let identity = ObjectIdentifier(source)
        if sourceID != identity { image = nil; deferredTools = [] }
        sourceID = identity
        let token = request, workerRenderer = renderer
        updating = true
        task = Task { @MainActor [weak self] in
            defer { if self?.request == token { self?.updating = false; self?.task = nil } }
            do {
                // Coalesce slider events without disabling any configuration UI.
                try await Task.sleep(for: .milliseconds(100))
                let worker = Task.detached(priority: .userInitiated) { try await workerRenderer.render(source, steps: steps) }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, self.request == token, self.sourceID == identity else { return }
                self.image = result.image; self.deferredTools = result.deferredTools; self.isCurrent = true
            } catch is CancellationError { }
            catch let failure {
                guard let self, !Task.isCancelled, self.request == token else { return }
                self.error = failure.localizedDescription
            }
        }
    }
}
