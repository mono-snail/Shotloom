import AppKit
import Darwin

enum LocalWorkflowFiles {
    static func write(_ data: Data, to destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".DeskCapture-workflow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        try Task.checkCancellation()
        try data.write(to: stage, options: .withoutOverwriting)
        try beforeCommit?()
        try Task.checkCancellation()
        guard Darwin.rename(stage.path, destination.path) == 0 else {
            throw CaptureError.message(L10n.text("流程文件保存失败，原目标保持。"))
        }
    }
}

struct LocalWorkflowStep: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case trim, resize, rotate, mirror, watermark, beautify, sensitiveReview, ocr
        var id: String { rawValue }
        var title: String { switch self { case .trim: L10n.text("裁掉留白"); case .resize: L10n.text("限制长边"); case .rotate: L10n.text("顺时针旋转"); case .mirror: L10n.text("翻转"); case .watermark: L10n.text("水印"); case .beautify: L10n.text("美化"); case .sensitiveReview: L10n.text("敏感信息人工复核"); case .ocr: L10n.text("识别文字") } }
    }
    var id = UUID()
    var kind: Kind
    var value: Int = 0
    var presetData: Data? = nil
    var watermark: ImageWatermark? = nil
    var appearance: WorkflowAppearance? = nil

    static func configured(_ kind: Kind) -> Self {
        var step = Self(kind: kind, value: kind == .trim ? 8 : kind == .resize ? 2400 : [.rotate, .mirror].contains(kind) ? 1 : 0)
        if kind == .watermark { step.watermark = .init(enabled: true) }
        if kind == .beautify { step.appearance = .init() }
        return step
    }
}
struct LocalWorkflowRecipe: Codable, Identifiable, Equatable {
    var version = 2
    var id = UUID()
    var name = L10n.text("截图整理")
    var steps: [LocalWorkflowStep] = [.init(kind: .resize, value: 2400)]
    var iconName: String? = nil
    var toolbarSymbol: String { WorkflowIcon.symbols.contains(iconName ?? "") ? iconName! : "bolt.fill" }
    var inCaptureToolbar: Bool? = nil
    var output: WorkflowOutput? = nil
    var delivery: WorkflowOutput { output ?? .init(kind: .preview) }
    func validate() throws {
        guard (1...2).contains(version), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              (1...12).contains(steps.count), Set(steps.map(\.id)).count == steps.count else {
            throw CaptureError.message(L10n.text("流程名称需为1–40字、包含1–12步；文件版本需受支持。"))
        }
        guard steps.filter({ $0.kind == .sensitiveReview }).count <= 1 else { throw CaptureError.message(L10n.text("敏感信息复核最多一步。")) }
        guard iconName == nil || WorkflowIcon.symbols.contains(iconName!) else { throw CaptureError.message(L10n.text("请选择有效的流程图标。")) }
        try delivery.validate(hasText: steps.last?.kind == .ocr)
        for (index, step) in steps.enumerated() {
            guard step.watermark == nil || step.kind == .watermark,
                  step.appearance == nil || step.kind == .beautify else { throw CaptureError.message(L10n.text("步骤参数与工具不匹配。")) }
            try Task.checkCancellation()
            switch step.kind {
            case .trim: guard (0...64).contains(step.value), step.presetData == nil else { throw CaptureError.message(L10n.text("裁边容差需0–64。")) }
            case .resize: guard (16...8000).contains(step.value), step.presetData == nil else { throw CaptureError.message(L10n.text("限制长边需16–8000像素。")) }
            case .rotate: guard (1...3).contains(step.value), step.presetData == nil else { throw CaptureError.message(L10n.text("旋转需1–3个直角。")) }
            case .mirror: guard (1...2).contains(step.value), step.presetData == nil else { throw CaptureError.message(L10n.text("请选择水平或垂直翻转。")) }
            case .watermark:
                guard let watermark = step.watermark, step.value == 0, step.presetData == nil else { throw CaptureError.message(L10n.text("请配置水印。")) }
                try watermark.validate()
            case .ocr: guard index == steps.count - 1, step.presetData == nil, step.value == 0 else { throw CaptureError.message(L10n.text("文字识别必须放在最后一步，以免识别文字与图片不一致。")) }
            case .sensitiveReview:
                guard step.value == 0, step.presetData == nil,
                      steps.dropFirst(index + 1).allSatisfy({ $0.kind == .ocr }) else { throw CaptureError.message(L10n.text("敏感信息复核需放在所有图片处理之后；复核后只能识别已遮盖图片的文字。")) }
            case .beautify:
                guard step.value == 0 else { throw CaptureError.message(L10n.text("美化参数无效。")) }
                if let appearance = step.appearance {
                    guard step.presetData == nil else { throw CaptureError.message(L10n.text("美化不能同时使用两组参数。")) }
                    try appearance.validate()
                } else {
                    guard let data = step.presetData else { throw CaptureError.message(L10n.text("请配置美化参数或选择已有预设。")) }
                    _ = try TutorialPreset.decode(data)
                }
            }
        }
    }
}
struct LocalWorkflowResult { let image: CGImage; let text: String?; let completedSteps: Int }
enum LocalWorkflowProcessor {
    static func run(_ image: CGImage, recipe: LocalWorkflowRecipe,
                    progress: (@Sendable (Int, String) async -> Void)? = nil,
                    rules: [SensitiveRule] = [],
                    review: (@Sendable (LocalWorkflowReviewInput) async throws -> [CGRect])? = nil,
                    reviewScanner: (@Sendable (CGImage, [SensitiveRule]) async throws -> [SensitiveReviewCandidate])? = nil) async throws -> LocalWorkflowResult {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try recipe.validate()
            guard review != nil || !recipe.steps.contains(where: { $0.kind == .sensitiveReview }) else { throw CaptureError.message(L10n.text("敏感信息步骤需要可见人工复核，未生成可交付结果。")) }
            guard image.width > 0, image.height > 0, Double(image.width) * Double(image.height) <= 32_000_000 else { throw CaptureError.message(L10n.text("流程输入最多3200万像素。")) }
            var result = image, text: String?
            for (index, step) in recipe.steps.enumerated() {
                try Task.checkCancellation(); await progress?(index, step.kind.title)
                try Task.checkCancellation()
                switch step.kind {
                case .trim, .resize, .rotate, .mirror, .watermark, .beautify:
                    result = try transform(result, step: step)
                case .sensitiveReview:
                    let candidates: [SensitiveReviewCandidate]
                    if let reviewScanner { candidates = try await reviewScanner(result, rules) }
                    else { candidates = try await LocalWorkflowSensitive.scan(result, rules: rules) }
                    try Task.checkCancellation()
                    guard let review else { throw CaptureError.message(L10n.text("人工复核入口已关闭。")) }
                    let bounds = try await review(LocalWorkflowReviewInput(image: result, candidates: candidates))
                    try Task.checkCancellation()
                    result = try SensitiveBatchIO.flattened(result, bounds: bounds)
                case .ocr: text = try await CaptureEngine.recognize(result)
                }
                guard Double(result.width) * Double(result.height) <= 32_000_000 else { throw CaptureError.message(L10n.text("步骤输出超过3200万像素，尚未交付。")) }
            }
            try Task.checkCancellation(); return LocalWorkflowResult(image: result, text: text, completedSteps: recipe.steps.count)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    /// One implementation for visual tools, shared by live preview and delivery.
    /// Callers validate parameters before entering and run away from the main actor.
    static func transform(_ image: CGImage, step: LocalWorkflowStep) throws -> CGImage {
        try Task.checkCancellation()
        let result: CGImage
        switch step.kind {
        case .trim: result = try CaptureImageCleanup.trim(image, tolerance: step.value)
        case .resize:
            let ratio = min(1, Double(step.value) / Double(max(image.width, image.height)))
            result = ratio < 1 ? try CaptureImageTransform.render(image,
                width: max(1, Int((Double(image.width) * ratio).rounded())),
                height: max(1, Int((Double(image.height) * ratio).rounded()))) : image
        case .rotate: result = try CaptureImageTransform.render(image, turns: step.value)
        case .mirror: result = try CaptureImageTransform.render(image, flipHorizontal: step.value == 1, flipVertical: step.value == 2)
        case .watermark:
            guard let watermark = step.watermark else { throw CaptureError.message(L10n.text("请配置水印。")) }
            result = try watermark.applying(to: image)
        case .beautify:
            if let appearance = step.appearance {
                result = try CaptureBeautifier.render(image, style: appearance.style, paddingPercent: appearance.padding,
                    roundness: appearance.roundness, layout: appearance.layout)
            } else if let data = step.presetData { result = try TutorialPreset.decode(data).render(image) }
            else { throw CaptureError.message(L10n.text("请配置美化参数。")) }
        case .ocr, .sensitiveReview:
            throw CaptureError.message(L10n.text("该工具需要运行流程后处理。"))
        }
        try Task.checkCancellation()
        guard Double(result.width) * Double(result.height) <= 32_000_000 else {
            throw CaptureError.message(L10n.text("步骤输出超过3200万像素，尚未交付。"))
        }
        return result
    }

}
actor LocalWorkflowLibrary {
    static let shared = LocalWorkflowLibrary()
    let directory: URL
    init(directory: URL? = nil) {
        let diagnostic = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("workflows") }
        self.directory = directory ?? diagnostic ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskCapture/Workflows")
    }
    func list() throws -> [LocalWorkflowRecipe] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles).filter { $0.pathExtension == "deskflow" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard files.count <= 50 else { throw CaptureError.message(L10n.text("流程最多50项。")) }
        let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard bytes <= 64_000_000 else { throw CaptureError.message(L10n.text("流程库超过64MB。")) }
        return try files.map { file in
            try Task.checkCancellation()
            let recipe = try Self.decode(Data(contentsOf: file))
            guard recipe.id.uuidString == file.deletingPathExtension().lastPathComponent else { throw CaptureError.message(L10n.text("流程标识与文件不一致。")) }; return recipe
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func decode(_ data: Data) throws -> LocalWorkflowRecipe {
        guard data.count <= 24_000_000 else { throw CaptureError.message(L10n.text("流程文件超过24MB。")) }
        let recipe = try JSONDecoder().decode(LocalWorkflowRecipe.self, from: data); try recipe.validate(); return recipe
    }
    static func encode(_ recipe: LocalWorkflowRecipe) throws -> Data {
        try recipe.validate(); let data = try JSONEncoder().encode(recipe)
        guard data.count <= 24_000_000 else { throw CaptureError.message(L10n.text("流程文件超过24MB。")) }; return data
    }
    func save(_ recipe: LocalWorkflowRecipe) throws {
        let data = try Self.encode(recipe), existing = try list()
        guard existing.contains(where: { $0.id == recipe.id }) || existing.count < 50 else { throw CaptureError.message(L10n.text("流程最多50项。")) }
        let bytes = try existing.filter { $0.id != recipe.id }.reduce(0) { $0 + (try directory.appendingPathComponent("\($1.id).deskflow").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard bytes + data.count <= 64_000_000 else { throw CaptureError.message(L10n.text("流程库保存后将超过64MB。")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LocalWorkflowFiles.write(data, to: directory.appendingPathComponent("\(recipe.id).deskflow"))
        NotificationCenter.default.post(name: .workflowLibraryChanged, object: nil)
    }
    func remove(_ id: UUID) throws { try Task.checkCancellation(); try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).deskflow")); NotificationCenter.default.post(name: .workflowLibraryChanged, object: nil) }
    func importFile(_ file: URL) throws -> LocalWorkflowRecipe {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 24_000_000 else { throw CaptureError.message(L10n.text("流程文件超过24MB。")) }
        var value = try Self.decode(Data(contentsOf: file)); value.id = UUID()
        // Imported recipes retain tool settings, but local delivery destinations
        // and toolbar exposure must be deliberately chosen on this Mac.
        value.inCaptureToolbar = false
        value.output?.directoryBookmark = nil; value.output?.directoryName = nil
        try save(value); return value
    }
}
