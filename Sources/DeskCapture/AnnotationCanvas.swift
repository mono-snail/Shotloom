import AppKit
import CoreText

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case arrow, curvedArrow, line, rectangle, roundedRectangle, ellipse, pen, redact, highlight, text, step, mosaic, icon, spotlight, magnify, measure, erase, replace, image
    var id: String { rawValue }
    static let primary: [AnnotationTool] = [.arrow, .rectangle, .pen, .redact]
    static let additional: [AnnotationTool] = [.text, .ellipse, .curvedArrow, .highlight, .step, .mosaic, .icon, .spotlight, .magnify, .measure, .erase]
    static let shapes: [AnnotationTool] = [.arrow, .curvedArrow, .line, .rectangle, .roundedRectangle, .ellipse]
    var isShape: Bool { Self.shapes.contains(self) }
    var isClosedShape: Bool { [.rectangle, .roundedRectangle, .ellipse].contains(self) }
    var title: String {
        switch self {
        case .arrow: return L10n.text("箭头"); case .line: return L10n.text("直线"); case .rectangle: return L10n.text("方框"); case .roundedRectangle: return L10n.text("圆角框")
        case .ellipse: return L10n.text("圆圈"); case .pen: return L10n.text("画笔"); case .redact: return L10n.text("彻底遮盖"); case .highlight: return L10n.text("高亮")
        case .text: return L10n.text("文字"); case .step: return L10n.text("步骤编号"); case .mosaic: return L10n.text("马赛克"); case .icon: return L10n.text("矢量图标")
        case .spotlight: return L10n.text("聚光灯"); case .magnify: return L10n.text("局部放大"); case .measure: return L10n.text("测量标尺")
        case .curvedArrow: return L10n.text("曲线箭头"); case .erase: return L10n.text("背景修复"); case .replace: return L10n.text("改写原文字"); case .image: return L10n.text("图片叠层")
        }
    }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"; case .line: return "line.diagonal"; case .rectangle: return "rectangle"; case .roundedRectangle: return "rectangle.roundedtop"
        case .ellipse: return "circle"; case .pen: return "pencil.tip"; case .redact: return "rectangle.fill"; case .highlight: return "highlighter"
        case .text: return "textformat"; case .step: return "1.circle"; case .mosaic: return "square.grid.3x3.fill"; case .icon: return "sparkles.rectangle.stack"
        case .spotlight: return "viewfinder.circle"; case .magnify: return "plus.magnifyingglass"; case .measure: return "ruler"
        case .curvedArrow: return "arrow.uturn.up"; case .erase: return "eraser"; case .replace: return "text.badge.checkmark"; case .image: return "photo.on.rectangle"
        }
    }
}

enum AnnotationTextStyle: String, CaseIterable, Identifiable, Codable {
    case plain, label, callout, outlined, code
    var id: String { rawValue }
    var title: String { switch self { case .plain: L10n.text("简洁"); case .label: L10n.text("标签"); case .callout: L10n.text("气泡"); case .outlined: L10n.text("描边"); case .code: L10n.text("代码") } }
}

enum AnnotationFill: String, CaseIterable, Identifiable, Codable {
    case outline, solid, translucent
    var id: String { rawValue }
    var title: String { switch self { case .outline: L10n.text("描边"); case .solid: L10n.text("实心"); case .translucent: L10n.text("透色") } }
    var symbol: String { switch self { case .outline: "square"; case .solid: "square.fill"; case .translucent: "square.on.square" } }
}

enum MosaicStyle: String, CaseIterable, Identifiable, Codable {
    case pixel, soft, crystal, stripe
    var id: String { rawValue }
    var title: String { switch self { case .pixel: L10n.text("像素"); case .soft: L10n.text("柔雾"); case .crystal: L10n.text("晶格"); case .stripe: L10n.text("光栅") } }
    var symbol: String { switch self { case .pixel: "square.grid.3x3.fill"; case .soft: "circle.dotted.circle.fill"; case .crystal: "hexagon.fill"; case .stripe: "line.3.horizontal.decrease" } }
}

enum VectorIcon: String, CaseIterable, Identifiable, Codable {
    case star, heart, check, bolt, sparkle, warning, pin, cursor
    var id: String { rawValue }
    var title: String { switch self {
        case .star: L10n.text("星星"); case .heart: L10n.text("爱心"); case .check: L10n.text("对勾"); case .bolt: L10n.text("闪电")
        case .sparkle: L10n.text("闪光"); case .warning: L10n.text("提醒"); case .pin: L10n.text("定位"); case .cursor: L10n.text("指针")
    } }
    var symbol: String { switch self {
        case .star: "star.fill"; case .heart: "heart.fill"; case .check: "checkmark.seal.fill"; case .bolt: "bolt.fill"
        case .sparkle: "sparkle"; case .warning: "exclamationmark.triangle.fill"; case .pin: "mappin.circle.fill"; case .cursor: "cursorarrow.rays"
    } }
}

enum AnnotationColor: String, CaseIterable, Identifiable {
    case coral, orange, yellow, green, cyan, violet, white, black
    var id: String { rawValue }
    var title: String { switch self { case .coral: return L10n.text("珊瑚红"); case .orange: return L10n.text("橙色"); case .cyan: return L10n.text("冰青"); case .violet: return L10n.text("紫色"); case .yellow: return L10n.text("黄色"); case .green: return L10n.text("绿色"); case .white: return L10n.text("白色"); case .black: return L10n.text("黑色") } }
    var color: NSColor {
        switch self { case .coral: return NSColor(calibratedRed: 1, green: 0.32, blue: 0.38, alpha: 1)
        case .orange: return .systemOrange; case .violet: return .systemPurple
        case .cyan: return NSColor(calibratedRed: 0.2, green: 0.85, blue: 0.95, alpha: 1)
        case .yellow: return .systemYellow; case .green: return .systemGreen; case .white: return .white; case .black: return .black }
    }
}

struct Annotation {
    var id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor = AnnotationColor.coral.color
    var width: CGFloat = 6
    var text: String = ""
    var number: Int = 1
    var fontSize: CGFloat = 28
    var fill: AnnotationFill = .outline
    var mosaicStyle: MosaicStyle = .pixel
    var mosaicStrength: CGFloat = 3
    var icon: VectorIcon = .star
    var curvature: CGFloat = 0.3
    var textStyle: AnnotationTextStyle = .plain
    var opacity: CGFloat = 1
    var fontName: String?
    var fontTracking: CGFloat?
    var textOriginOffset: CGPoint?
    var repairMode: RepairMode?
    var repairAnchor: CGPoint?
    var overlayPNG: Data?
    var overlayImage: CGImage?
}

struct AnnotationArchive: Codable, Equatable {
    let tool: AnnotationTool
    let points: [CGPoint]
    let rgba: [CGFloat]
    let calibrated: Bool
    let sRGB: Bool?
    let width: CGFloat
    let text: String
    let number: Int
    let fontSize: CGFloat
    let fill: AnnotationFill
    let mosaicStyle: MosaicStyle
    let mosaicStrength: CGFloat
    let icon: VectorIcon
    let curvature: CGFloat?
    let textStyle: AnnotationTextStyle?
    let opacity: CGFloat?
    let fontName: String?
    let fontTracking: CGFloat?
    let textOriginOffset: CGPoint?
    let repairMode: RepairMode?
    let repairAnchor: CGPoint?
    let overlayPNG: Data?
    init(_ mark: Annotation) {
        // Dynamic system colors must be resolved before reading their color space/components.
        let generic = mark.color.usingColorSpace(.genericRGB)
        calibrated = generic?.isEqual(mark.color) == true; sRGB = !calibrated
        let color = calibrated ? generic! : (mark.color.usingColorSpace(.sRGB) ?? NSColor.red)
        tool = mark.tool; points = mark.points
        rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        width = mark.width; text = mark.text; number = mark.number; fontSize = mark.fontSize
        fill = mark.fill; mosaicStyle = mark.mosaicStyle; mosaicStrength = mark.mosaicStrength; icon = mark.icon
        curvature = mark.curvature; textStyle = mark.textStyle; opacity = mark.opacity; overlayPNG = mark.overlayPNG
        fontName = mark.fontName; repairMode = mark.repairMode; repairAnchor = mark.repairAnchor
        fontTracking = mark.fontTracking; textOriginOffset = mark.textOriginOffset
    }
    func makeMark() -> Annotation {
        var mark = Annotation(tool: tool, points: points)
        if rgba.count == 4 {
            if sRGB == true { mark.color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) }
            else { mark.color = calibrated
                ? NSColor(calibratedRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
                : NSColor(deviceRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) }
        }
        mark.width = width; mark.text = text; mark.number = number; mark.fontSize = fontSize
        mark.fill = fill; mark.mosaicStyle = mosaicStyle; mark.mosaicStrength = mosaicStrength; mark.icon = icon
        mark.curvature = curvature ?? 0.3; mark.textStyle = textStyle ?? .plain; mark.opacity = opacity ?? 1
        mark.fontName = fontName; mark.repairMode = repairMode; mark.repairAnchor = repairAnchor
        mark.fontTracking = fontTracking; mark.textOriginOffset = textOriginOffset
        mark.overlayPNG = overlayPNG
        if let overlayPNG, let source = CGImageSourceCreateWithData(overlayPNG as CFData, nil) {
            mark.overlayImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return mark
    }
}

private struct CaptureProjectArchive: Codable {
    let version: Int
    let sourcePNG: Data
    let marks: [AnnotationArchive]
    let backingScale: CGFloat?
    var tutorialPreset: TutorialPreset? = nil
}

@MainActor
private final class PixelDocumentOwner {
    weak var document: AnnotationDocument?
    init(_ document: AnnotationDocument) { self.document = document }
}

final class AnnotationDocument: ObservableObject {
    let original: CGImage
    var backingScale: CGFloat = 1
    @Published var tool: AnnotationTool = .arrow
    @Published var selectingMark = false
    @Published var color: AnnotationColor = .coral { didSet { mutateSelected { $0.color = customColor ?? color.color } } }
    @Published var customColor: NSColor? { didSet { mutateSelected(group: "color") { $0.color = customColor ?? color.color } } }
    @Published var lineWidth: CGFloat = 6 { didSet { mutateSelected(group: "width") { $0.width = lineWidth } } }
    @Published var fontSize: CGFloat = 28 { didSet { mutateSelected(group: "font") { $0.fontSize = fontSize } } }
    @Published var fill: AnnotationFill = .outline { didSet { mutateSelected { $0.fill = fill } } }
    @Published var mosaicStyle: MosaicStyle = .pixel { didSet { mutateSelected { $0.mosaicStyle = mosaicStyle } } }
    @Published var mosaicStrength: CGFloat = 3 { didSet { mutateSelected(group: "strength") { $0.mosaicStrength = mosaicStrength } } }
    @Published var icon: VectorIcon = .star { didSet { mutateSelected { $0.icon = icon } } }
    @Published var fontName = "" { didSet { mutateSelected { $0.fontName = fontName.isEmpty ? nil : fontName } } }
    @Published var repairMode: RepairMode = .smooth
    @Published var repairAnchor: CGPoint?
    @Published var iconSize: CGFloat = 72
    @Published var curvature: CGFloat = 0.3 { didSet { mutateSelected(group: "curve") { $0.curvature = curvature } } }
    @Published var textStyle: AnnotationTextStyle = .plain { didSet { mutateSelected { $0.textStyle = textStyle } } }
    @Published var opacity: CGFloat = 1 { didSet { mutateSelected(group: "opacity") { $0.opacity = opacity } } }
    @Published var selectedText = "" { didSet {
        if selectedMark?.tool == .text || selectedMark?.tool == .replace { mutateSelected(group: "text") { $0.text = selectedText } }
    } }
    private(set) var renderRevision = 0
    @Published var marks: [Annotation] = [] { didSet { renderRevision &+= 1 } }
    @Published var ocrLines: [OCRLine] = []
    @Published var ocrFontFits: [UUID: OCRFontFit] = [:]
    @Published var tutorialPreset: TutorialPreset? { didSet { renderRevision &+= 1 } }
    @Published private(set) var replacingOCR = false
    @Published private(set) var ocrReplacementError: String?
    weak var presentationWindow: NSWindow?
    private var ocrReplacementWorker: Task<Annotation, Error>?
    private var ocrReplacementToken = UUID()
    var beforeOCRReplacementCommitForDiagnostics: (() -> Void)?
    @Published var showsOCRLocations = false
    @Published var snapsAnnotations = true
    @Published private(set) var arrangingMarks = false
    @Published private(set) var arrangementError: String?
    private var arrangementToken = UUID()
    private var arrangementWorker: Task<[Annotation], Error>?
    var beforeArrangementCommitForDiagnostics: (() -> Void)?
    @Published private(set) var selectedMarkIDs: Set<UUID> = []
    @Published private(set) var selectedMarkID: UUID? {
        didSet {
            if let selectedMarkID { selectedMarkIDs.insert(selectedMarkID) }
            else { selectedMarkIDs = [] }
        }
    }
    @Published private(set) var preparingPixels = false
    @Published private(set) var pixelPreparationError: String?
    private var pixelToken = UUID()
    private var pixelWorker: Task<[Annotation], Error>?
    private var pixelRenderWorker: Task<CGImage, Error>?
    private var pixelCommitTask: Task<Void, Never>?
    private var pixelWindowObserver: NSObjectProtocol?
    var beforePixelCommitForDiagnostics: (() -> Void)?
    private var undoStates: [[Annotation]] = []
    private var redoStates: [[Annotation]] = []
    private var latestContinuous: (group: String, id: UUID, time: TimeInterval)?
    private var loadingSelection = false
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }
    var selectedMark: Annotation? { marks.first { $0.id == selectedMarkID } }
    var commitPendingText: (() -> Void)?
    init(image: CGImage) { original = image }
    convenience init(projectData: Data) throws {
        guard projectData.count <= 100_000_000 else { throw CaptureError.message(L10n.text("工程超过 100 MB。")) }
        let archive = try JSONDecoder().decode(CaptureProjectArchive.self, from: projectData)
        guard archive.version == 1,
              archive.marks.count <= 2000,
              archive.marks.reduce(0, { $0 + $1.points.count }) <= 500_000,
              archive.marks.allSatisfy({ $0.width.isFinite && (0...1000).contains($0.width) && $0.fontSize.isFinite && (1...2000).contains($0.fontSize)
                  && ($0.fontTracking.map { $0.isFinite && abs($0) <= 256 } ?? true)
                  && ($0.textOriginOffset.map { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 60000 && abs($0.y) <= 60000 } ?? true)
                  && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100 && abs($0.y) <= 100 } }),
              let source = CGImageSourceCreateWithData(archive.sourcePNG as CFData, nil) else {
            throw CaptureError.message(L10n.text("工程文件无法读取或版本不受支持。"))
        }
        let image = try CaptureImageRead.decode(source)
        for mark in archive.marks {
            if let data = mark.overlayPNG {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CaptureError.message(L10n.text("叠加图片无效。")) }
                _ = try CaptureImageRead.decode(source)
            }
        }
        self.init(image: image)
        if let scale = archive.backingScale, scale.isFinite, (1...4).contains(scale) { backingScale = scale }
        marks = archive.marks.map { $0.makeMark() }
        if let preset = archive.tutorialPreset {
            try preset.validate(); tutorialPreset = preset
            // This object has not escaped its initializer. Restore next-mark defaults
            // without touching global preferences or mutating the restored marks.
            if let style = preset.annotation {
                customColor = NSColor(srgbRed: style.rgba[0], green: style.rgba[1], blue: style.rgba[2], alpha: style.rgba[3])
                tool = style.tool; lineWidth = style.width; fontSize = style.fontSize; fontName = style.fontName ?? ""
                fill = style.fill; textStyle = style.textStyle; mosaicStyle = style.mosaicStyle
                mosaicStrength = style.mosaicStrength; curvature = style.curvature; opacity = style.opacity
                if let savedIcon = style.icon { icon = savedIcon }; if let size = style.iconSize { iconSize = size }
            }
        }
    }
    func projectData() throws -> Data {
        try Self.encodeProject(original: original, marks: marks.map(AnnotationArchive.init), backingScale: backingScale, tutorialPreset: tutorialPreset)
    }
    static func encodeProject(original: CGImage, marks: [AnnotationArchive], backingScale: CGFloat, tutorialPreset: TutorialPreset? = nil) throws -> Data {
        try tutorialPreset?.validate()
        guard let png = NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:]) else {
            throw CaptureError.message(L10n.text("工程原图编码失败。"))
        }
        let data = try JSONEncoder().encode(CaptureProjectArchive(version: 1, sourcePNG: png, marks: marks, backingScale: backingScale, tutorialPreset: tutorialPreset))
        guard data.count <= 100_000_000 else { throw CaptureError.message(L10n.text("工程超过100MB，未保存。")) }; return data
    }
    func makeMark(tool: AnnotationTool, points: [CGPoint], text: String = "") -> Annotation {
        var mark = Annotation(tool: tool, points: points, color: customColor ?? color.color, width: lineWidth, text: text,
                   number: marks.filter { $0.tool == .step }.count + 1, fontSize: fontSize,
                   fill: fill, mosaicStyle: mosaicStyle, mosaicStrength: mosaicStrength, icon: icon)
        mark.curvature = curvature; mark.textStyle = textStyle; mark.opacity = opacity
        mark.fontName = fontName.isEmpty ? nil : fontName; mark.repairMode = repairMode; mark.repairAnchor = repairAnchor
        return mark
    }
    func selectColor(_ preset: AnnotationColor) {
        loadingSelection = true; color = preset; customColor = nil; loadingSelection = false
        mutateSelected { $0.color = preset.color }
    }
    func iconEnd(from first: CGPoint, toward last: CGPoint) -> CGPoint {
        let dx = last.x - first.x, dy = last.y - first.y
        let directionX: CGFloat = dx < 0 ? -1 : 1
        let directionY: CGFloat = dy < 0 ? -1 : 1
        let availableX = (directionX > 0 ? 1 - first.x : first.x) * CGFloat(original.width)
        let availableY = (directionY > 0 ? 1 - first.y : first.y) * CGFloat(original.height)
        let side = min(max(abs(dx) * CGFloat(original.width), abs(dy) * CGFloat(original.height)), availableX, availableY)
        return CGPoint(x: first.x + directionX * side / CGFloat(original.width),
                       y: first.y + directionY * side / CGFloat(original.height))
    }
    func finishIcon(_ mark: Annotation) -> Annotation {
        guard mark.tool == .icon, let first = mark.points.first, let last = mark.points.last,
              hypot(first.x - last.x, first.y - last.y) < 0.004 else { return mark }
        var result = mark
        let side = min(iconSize, (1 - first.x) * CGFloat(original.width), (1 - first.y) * CGFloat(original.height))
        result.points = [first, CGPoint(x: first.x + side / CGFloat(original.width),
                                        y: first.y + side / CGFloat(original.height))]
        return result
    }
    private func checkpoint(_ state: [Annotation], group: String? = nil) {
        let now = Date().timeIntervalSinceReferenceDate
        if let group, let id = selectedMarkID, let latestContinuous,
           latestContinuous.group == group, latestContinuous.id == id, now - latestContinuous.time < 0.5 {
            self.latestContinuous = (group, id, now)
            return
        }
        if let group, let id = selectedMarkID { latestContinuous = (group, id, now) }
        else { latestContinuous = nil }
        undoStates.append(state)
        if undoStates.count > 80 { undoStates.removeFirst() }
        redoStates.removeAll()
    }
    @MainActor func reportPixelPreparationError(_ message: String) { pixelPreparationError = message }
    @MainActor func cancelPixelPreparation() {
        pixelToken = UUID(); pixelWorker?.cancel(); pixelRenderWorker?.cancel(); pixelCommitTask?.cancel()
        pixelWorker = nil; pixelRenderWorker = nil; pixelCommitTask = nil; preparingPixels = false
        if let pixelWindowObserver { NotificationCenter.default.removeObserver(pixelWindowObserver); self.pixelWindowObserver = nil }
    }
    @MainActor func waitForCanvasPixels() async { await pixelCommitTask?.value }
    @MainActor func canvasPixelWorkForDiagnostics() -> Task<Void, Never>? { pixelCommitTask }
    @MainActor private func watchPixelWindow(_ window: NSWindow?) {
        if let window {
            let owner = PixelDocumentOwner(self)
            pixelWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { owner.document?.cancelPixelPreparation() }
            }
        }
    }
    @MainActor private func finishPixelCommand(_ token: UUID) {
        guard token == pixelToken else { return }
        preparingPixels = false; pixelWorker = nil; pixelRenderWorker = nil; pixelCommitTask = nil
        if let pixelWindowObserver { NotificationCenter.default.removeObserver(pixelWindowObserver); self.pixelWindowObserver = nil }
    }
    @MainActor private func beginPixelMutation(selection: Set<UUID>, selecting: Bool = false, usage: String? = nil,
        operation: @escaping @Sendable (CGImage, [Annotation]) throws -> [Annotation]) {
        guard !preparingPixels, !replacingOCR, !arrangingMarks else { pixelPreparationError = L10n.text("请先等待当前像素处理完成，或取消后重试。"); return }
        let source = original, snapshot = marks, revision = renderRevision, expectedSelection = selectedMarkIDs, owner = presentationWindow
        let token = UUID(); pixelToken = token; preparingPixels = true; pixelPreparationError = nil; watchPixelWindow(owner)
        let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); let result = try operation(source, snapshot); try Task.checkCancellation(); return result }
        pixelWorker = worker
        pixelCommitTask = Task { @MainActor [weak self] in
            guard let self else { worker.cancel(); return }
            defer { self.finishPixelCommand(token) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                self.beforePixelCommitForDiagnostics?()
                guard !Task.isCancelled, self.pixelToken == token, self.renderRevision == revision, self.selectedMarkIDs == expectedSelection,
                      owner?.isVisible != false else { return }
                self.checkpoint(snapshot); self.marks = result
                self.selectedMarkID = result.last(where: { selection.contains($0.id) })?.id; self.selectedMarkIDs = selection
                if selecting { self.selectingMark = true }
                if let usage { LocalUsage.shared.record(usage) }
            } catch is CancellationError { }
            catch { if self.pixelToken == token { self.pixelPreparationError = error.localizedDescription } }
        }
    }
    private func preparedRequired(_ mark: Annotation) throws -> Annotation {
        try Task.checkCancellation()
        var seed = mark
        if seed.tool == .erase || seed.tool == .replace {
            guard seed.points.count >= 2, seed.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { throw CaptureError.message(L10n.text("修复区域超出画布，未修改原工程。")) }
            let a = seed.points.first!, b = seed.points.last!
            if seed.repairMode == .texture || seed.repairMode == .clone {
                guard abs(a.x - b.x) * abs(a.y - b.y) * CGFloat(original.width) * CGFloat(original.height) <= 20_000_000 else { throw CaptureError.message(L10n.text("单次纹理/取样修复最多2000万像素，请缩小区域。")) }
            }
            seed.overlayImage = nil; seed.overlayPNG = nil
        }
        if seed.tool == .image, seed.overlayPNG == nil, let image = seed.overlayImage, Double(image.width) * Double(image.height) > 20_000_000 { throw CaptureError.message(L10n.text("单个图片叠层最多2000万像素。")) }
        let result = prepared(seed)
        if mark.tool == .erase || mark.tool == .replace || mark.tool == .image {
            guard result.overlayImage != nil, result.overlayPNG != nil else { throw CaptureError.message(L10n.text("像素修复或图片编码失败，未修改画面与撤销记录。")) }
        }
        return result
    }
    @MainActor func addOnCanvas(_ mark: Annotation) {
        guard mark.tool == .erase || mark.tool == .replace || (mark.tool == .image && mark.overlayPNG == nil) else { add(mark); return }
        beginPixelMutation(selection: [], usage: "annotation") { source, base in base + [try AnnotationDocument(image: source).preparedRequired(mark)] }
    }
    @MainActor func duplicateSelectedOnCanvas() {
        let chosen = marks.filter { selectedMarkIDs.contains($0.id) }
        guard chosen.contains(where: { $0.tool == .erase || $0.tool == .replace }) else { duplicateSelected(); return }
        let points = chosen.flatMap(\.points), dx = min(0.025, 1 - (points.map(\.x).max() ?? 1)), dy = max(-0.025, -(points.map(\.y).min() ?? 0))
        let copies = chosen.map { mark -> Annotation in var result = mark; result.id = UUID(); result.points = mark.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }; return result }
        beginPixelMutation(selection: Set(copies.map(\.id))) { source, base in
            let snapshot = AnnotationDocument(image: source)
            return base + (try copies.map { try snapshot.preparedRequired($0) })
        }
    }
    @MainActor func commitMoveOnCanvas(from original: [Annotation]) {
        if preparingPixels { cancelPixelPreparation() }
        if replacingOCR { cancelOCRReplacement() }
        if arrangingMarks { cancelArrangement() }
        guard original.count == marks.count, original.map(\.id) == marks.map(\.id) else { return }
        let changed = Set(zip(original, marks).filter { $0.points != $1.points }.map { $1.id })
        guard !changed.isEmpty else { return }
        guard marks.contains(where: { changed.contains($0.id) && ($0.tool == .erase || $0.tool == .replace) }) else { commitMove(from: original); return }
        let proposed = marks, selection = selectedMarkIDs
        marks = original // A failed preparation must leave no provisional move.
        beginPixelMutation(selection: selection) { source, _ in
            let snapshot = AnnotationDocument(image: source)
            return try proposed.map { changed.contains($0.id) ? try snapshot.preparedRequired($0) : $0 }
        }
    }
    @MainActor func nudgeOnCanvas(x: CGFloat, y: CGFloat) {
        guard !preparingPixels else { return }
        let previous = marks
        moveSelected(from: previous, by: CGPoint(x: x / CGFloat(original.width), y: y / CGFloat(original.height)))
        commitMoveOnCanvas(from: previous)
    }
    @MainActor func addImageOnCanvas(_ image: CGImage) {
        let scale = min(CGFloat(original.width) * 0.65 / CGFloat(image.width), CGFloat(original.height) * 0.65 / CGFloat(image.height), 1)
        let w = CGFloat(image.width) * scale / CGFloat(original.width), h = CGFloat(image.height) * scale / CGFloat(original.height)
        var mark = makeMark(tool: .image, points: [.init(x: 0.5 - w / 2, y: 0.5 - h / 2), .init(x: 0.5 + w / 2, y: 0.5 + h / 2)])
        mark.overlayImage = image
        let seed = mark
        beginPixelMutation(selection: [seed.id], selecting: true, usage: "overlay") { source, base in base + [try AnnotationDocument(image: source).preparedRequired(seed)] }
    }
    @MainActor func liftContentOnCanvas(from a: CGPoint, to b: CGPoint) {
        var erase = makeMark(tool: .erase, points: [a, b]); erase.repairMode = .texture
        let image = makeMark(tool: .image, points: [a, b]), eraseSeed = erase
        beginPixelMutation(selection: [image.id], selecting: true) { source, base in
            let rect = CGRect(x: min(a.x, b.x) * CGFloat(source.width), y: (1 - max(a.y, b.y)) * CGFloat(source.height), width: abs(a.x - b.x) * CGFloat(source.width), height: abs(a.y - b.y) * CGFloat(source.height)).integral
            guard rect.width > 2, rect.height > 2, let crop = source.cropping(to: rect) else { throw CaptureError.message(L10n.text("选区无法提取，未修改图片。")) }
            let snapshot = AnnotationDocument(image: source)
            var lifted = image; lifted.overlayImage = crop
            return base + [try snapshot.preparedRequired(eraseSeed), try snapshot.preparedRequired(lifted)]
        }
    }
    @MainActor func renderForDelivery(_ action: @escaping @MainActor (CGImage) -> Void) {
        renderForDelivery(action, finished: {})
    }
    @MainActor func renderForDelivery(_ action: @escaping @MainActor (CGImage) -> Void,
                                      finished: @escaping @MainActor () -> Void) {
        guard !preparingPixels, !replacingOCR, !arrangingMarks else { pixelPreparationError = L10n.text("请先等待当前图像处理完成，或取消后交付。"); finished(); return }
        commitPendingText?()
        let source = original, snapshot = marks, revision = renderRevision, owner = presentationWindow, preset = tutorialPreset
        let token = UUID(); pixelToken = token; preparingPixels = true; pixelPreparationError = nil; watchPixelWindow(owner)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let copy = AnnotationDocument(image: source); copy.marks = snapshot; copy.tutorialPreset = preset
            guard let image = copy.render() else { throw CaptureError.message(L10n.text("图片合成失败，未交付。")) }
            try Task.checkCancellation(); return image
        }
        pixelRenderWorker = worker
        pixelCommitTask = Task { @MainActor [weak self] in
            guard let self else { worker.cancel(); finished(); return }
            defer { self.finishPixelCommand(token); finished() }
            do {
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                self.beforePixelCommitForDiagnostics?()
                guard !Task.isCancelled, self.pixelToken == token, self.renderRevision == revision, owner?.isVisible != false else { return }
                self.finishPixelCommand(token); action(image)
            } catch is CancellationError { }
            catch { if self.pixelToken == token { self.pixelPreparationError = error.localizedDescription } }
        }
    }
    func add(_ mark: Annotation) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { LocalUsage.shared.record(mark.tool == .image ? "overlay" : "annotation") }
        }
        checkpoint(marks); marks.append(prepared(mark)); selectedMarkID = nil }
    func addBatch(_ items: [Annotation]) { checkpoint(marks); marks.append(contentsOf: items.map(prepared)); selectedMarkID = nil }
    private func prepared(_ mark: Annotation) -> Annotation {
        var mark = mark
        if mark.tool == .erase || mark.tool == .replace, let a = mark.points.first, let b = mark.points.last {
            let patch = mark.repairMode == .texture || mark.repairMode == .clone
                ? CaptureRepair.texturePatch(original, normalized: a, b, anchor: mark.repairMode == .clone ? mark.repairAnchor : nil)
                : CaptureRepair.patch(original, normalized: a, b)
            if let patch { mark.overlayImage = patch; mark.overlayPNG = NSBitmapImageRep(cgImage: patch).representation(using: .png, properties: [:]) }
        }
        if mark.tool == .image, mark.overlayPNG == nil, let image = mark.overlayImage { mark.overlayPNG = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) }
        return mark
    }
    @MainActor func cancelOCRReplacement() {
        ocrReplacementToken = UUID(); ocrReplacementWorker?.cancel(); ocrReplacementWorker = nil; replacingOCR = false
    }
    @MainActor func replaceOCRLine(_ line: OCRLine, with text: String) async {
        guard !preparingPixels else { ocrReplacementError = L10n.text("请先完成或取消当前像素处理。"); return }
        guard !text.isEmpty, text.utf8.count <= 65_536 else { ocrReplacementError = L10n.text("改写内容为空或超过64KB。"); return }
        let bounds = line.bounds.insetBy(dx: -2 / CGFloat(original.width), dy: -2 / CGFloat(original.height))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isEmpty else { return }
        let seed = makeMark(tool: .replace, points: [bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY)], text: text)
        let source = original, fit = ocrFontFits[line.id], revision = renderRevision, owningWindow = presentationWindow
        let token = UUID(); ocrReplacementToken = token
        ocrReplacementWorker?.cancel(); replacingOCR = true; ocrReplacementError = nil
        let worker = Task.detached(priority: .userInitiated) { () throws -> Annotation in
            try Task.checkCancellation()
            var mark = seed
            mark.fontSize = max(8, line.bounds.height * CGFloat(source.height) * 0.84)
            if let fit {
                mark.fontName = fit.fontName; mark.fontSize = fit.sizePixels; mark.fontTracking = fit.trackingPixels
                mark.textOriginOffset = CGPoint(x: fit.originXPixels-bounds.minX*CGFloat(source.width),
                                               y: fit.baselinePixels-bounds.minY*CGFloat(source.height))
            }
            let font = mark.fontName.flatMap { NSFont(name: $0, size: mark.fontSize) } ?? NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold)
            let measured = (text as NSString).size(withAttributes: [.font: font, .kern: mark.fontTracking ?? 0]).width
            let available = line.bounds.width * CGFloat(source.width)
            if measured > available, measured > 0 {
                let ratio = available/measured; mark.fontSize *= ratio
                if let tracking = mark.fontTracking { mark.fontTracking = tracking*ratio }
            }
            guard mark.fontSize >= 6 else { throw CaptureError.message(L10n.text("新文字过长，无法在原行保持可读字号。请缩短内容或使用独立文字标注。")) }
            mark.color = CaptureRepair.foreground(source, bounds: line.bounds); mark.textStyle = .plain
            let patch = mark.repairMode == .texture || mark.repairMode == .clone
                ? CaptureRepair.texturePatch(source, normalized: bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: mark.repairMode == .clone ? mark.repairAnchor : nil)
                : CaptureRepair.patch(source, normalized: bounds.origin, CGPoint(x: bounds.maxX, y: bounds.maxY))
            guard let patch, let encoded = NSBitmapImageRep(cgImage: patch).representation(using: .png, properties: [:]) else {
                throw CaptureError.message(L10n.text("背景修复失败，原图与工程保持不变。"))
            }
            mark.overlayImage = patch; mark.overlayPNG = encoded
            try Task.checkCancellation(); return mark
        }
        ocrReplacementWorker = worker
        defer {
            if ocrReplacementToken == token { replacingOCR = false; ocrReplacementWorker = nil }
        }
        do {
            let mark = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            beforeOCRReplacementCommitForDiagnostics?()
            guard !Task.isCancelled, token == ocrReplacementToken, revision == renderRevision,
                  owningWindow?.isVisible != false else { return }
            checkpoint(marks); marks.append(mark); selectedMarkID = nil
            LocalUsage.shared.record("content.rewrite")
        } catch is CancellationError { }
        catch { if ocrReplacementToken == token { ocrReplacementError = error.localizedDescription } }
    }
    func addImage(_ image: CGImage) {
        let scale = min(CGFloat(original.width) * 0.65 / CGFloat(image.width), CGFloat(original.height) * 0.65 / CGFloat(image.height), 1)
        let w = CGFloat(image.width) * scale / CGFloat(original.width), h = CGFloat(image.height) * scale / CGFloat(original.height)
        var mark = makeMark(tool: .image, points: [CGPoint(x: 0.5 - w / 2, y: 0.5 - h / 2), CGPoint(x: 0.5 + w / 2, y: 0.5 + h / 2)])
        mark.overlayImage = image; mark.overlayPNG = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        add(mark); selectingMark = true
        selectMark(at: CGPoint(x: 0.5, y: 0.5), tolerance: .zero)
    }
    var overlayPixelWidth: CGFloat {
        guard let mark = selectedMark, let a = mark.points.first, let b = mark.points.last else { return 1 }
        return max(1, abs(a.x - b.x) * CGFloat(original.width))
    }
    func resizeSelectedImage(toWidth pixels: CGFloat) {
        guard let mark = selectedMark, mark.tool == .image, let image = mark.overlayImage,
              let a = mark.points.first, let b = mark.points.last else { return }
        let w = min(1, max(1 / CGFloat(original.width), pixels / CGFloat(original.width)))
        let h = w * CGFloat(original.width) * CGFloat(image.height) / CGFloat(image.width) / CGFloat(original.height)
        let factor = min(1, 1 / max(0.001, h)), width = w * factor, height = h * factor
        let x = min(1 - width, max(0, (a.x + b.x - width) / 2)), y = min(1 - height, max(0, (a.y + b.y - height) / 2))
        mutateSelected(group: "imagesize") { $0.points = [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y + height)] }
    }
    func undo() {
        if Thread.isMainThread, preparingPixels {
            let mutation = pixelWorker != nil
            MainActor.assumeIsolated { cancelPixelPreparation() }
            if mutation { return }
        }
        guard let state = undoStates.popLast() else { return }
        latestContinuous = nil
        redoStates.append(marks); marks = state
        if !marks.contains(where: { $0.id == selectedMarkID }) { selectedMarkID = nil }
    }
    func redo() {
        guard let state = redoStates.popLast() else { return }
        latestContinuous = nil
        undoStates.append(marks); marks = state
        if !marks.contains(where: { $0.id == selectedMarkID }) { selectedMarkID = nil }
    }
    private func mutateSelected(group: String? = nil, _ change: (inout Annotation) -> Void) {
        guard !loadingSelection, !selectedMarkIDs.isEmpty else { return }
        checkpoint(marks, group: group)
        var updated = marks
        for index in updated.indices where selectedMarkIDs.contains(updated[index].id) { change(&updated[index]) }
        marks = updated
    }
    func selectMark(at point: CGPoint, tolerance: CGPoint, additive: Bool = false) {
        latestContinuous = nil
        let hit = marks.reversed().first { mark in
            guard !mark.points.isEmpty else { return false }
            let geometry = geometryPoints(mark)
            let xs = geometry.map(\.x), ys = geometry.map(\.y)
            return point.x >= (xs.min() ?? 0) - tolerance.x && point.x <= (xs.max() ?? 0) + tolerance.x &&
                   point.y >= (ys.min() ?? 0) - tolerance.y && point.y <= (ys.max() ?? 0) + tolerance.y
        }?.id
        if additive {
            if let hit {
                if selectedMarkIDs.contains(hit) { selectedMarkIDs.remove(hit) }
                else { selectedMarkIDs.insert(hit) }
            }
            selectedMarkID = hit.flatMap { selectedMarkIDs.contains($0) ? $0 : nil } ?? marks.first(where: { selectedMarkIDs.contains($0.id) })?.id
        } else {
            selectedMarkIDs = Set(hit.map { [$0] } ?? []); selectedMarkID = hit
        }
        guard let mark = selectedMark else { return }
        loadingSelection = true
        lineWidth = mark.width; fontSize = mark.fontSize; fill = mark.fill; fontName = mark.fontName ?? ""; repairMode = mark.repairMode ?? .smooth; repairAnchor = mark.repairAnchor
        mosaicStyle = mark.mosaicStyle; mosaicStrength = mark.mosaicStrength; icon = mark.icon
        curvature = mark.curvature; textStyle = mark.textStyle; opacity = mark.opacity; selectedText = mark.text
        customColor = mark.color
        loadingSelection = false
    }
    func changeSelectedShape(to shape: AnnotationTool) {
        guard shape.isShape, selectedMark?.tool.isShape == true else { return }
        mutateSelected { if $0.tool.isShape { $0.tool = shape } }
    }
    @discardableResult
    func moveSelected(from original: [Annotation], by delta: CGPoint, snapTolerance: CGSize? = nil) -> [AnnotationSnapGuide] {
        let selected = original.filter { selectedMarkIDs.contains($0.id) }
        guard !selected.isEmpty else { return [] }
        let points = selected.flatMap(\.points)
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 1
        var delta = delta
        var snapResult: AnnotationSnapResult?
        if snapsAnnotations, let snapTolerance {
            let points = selected.flatMap { geometryPoints($0) }
            let group = CGRect(x: points.map(\.x).min() ?? minX, y: points.map(\.y).min() ?? minY,
                width: (points.map(\.x).max() ?? maxX) - (points.map(\.x).min() ?? minX),
                height: (points.map(\.y).max() ?? maxY) - (points.map(\.y).min() ?? minY))
            let targets = original.filter { !selectedMarkIDs.contains($0.id) }.map { mark -> CGRect in
                let p = geometryPoints(mark), a = CGPoint(x: p.map(\.x).min() ?? 0, y: p.map(\.y).min() ?? 0)
                return CGRect(x: a.x, y: a.y, width: (p.map(\.x).max() ?? a.x) - a.x, height: (p.map(\.y).max() ?? a.y) - a.y)
            }
            let result = AnnotationLayout.snap(delta, group: group, targets: targets, tolerance: snapTolerance)
            snapResult = result; delta = result.delta
        }
        let dx = min(1 - maxX, max(-minX, delta.x)), dy = min(1 - maxY, max(-minY, delta.y))
        var updated = original
        for index in updated.indices where selectedMarkIDs.contains(updated[index].id) {
            updated[index].points = updated[index].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        marks = updated
        return snapResult?.guides(afterApplying: CGPoint(x: dx, y: dy)) ?? []
    }
    func commitMove(from original: [Annotation]) {
        guard zip(original, marks).contains(where: { $0.points != $1.points }) else { return }
        checkpoint(original)
        var updated = marks
        for index in updated.indices where selectedMarkIDs.contains(updated[index].id) && (updated[index].tool == .erase || updated[index].tool == .replace) {
            updated[index] = prepared(updated[index])
        }
        marks = updated
    }
    func deleteSelected() {
        guard !selectedMarkIDs.isEmpty else { return }
        checkpoint(marks); marks.removeAll { selectedMarkIDs.contains($0.id) }; selectedMarkID = nil
    }
    func selectAllMarks() {
        selectedMarkIDs = Set(marks.map(\.id)); selectedMarkID = marks.last?.id; latestContinuous = nil
    }
    func duplicateSelected() {
        let selected = marks.filter { selectedMarkIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        checkpoint(marks)
        let points = selected.flatMap(\.points)
        let dx = min(0.025, 1 - (points.map(\.x).max() ?? 1)), dy = max(-0.025, -(points.map(\.y).min() ?? 0))
        let copies = selected.map { mark -> Annotation in
            var copy = mark; copy.id = UUID()
            copy.points = mark.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            return prepared(copy)
        }
        marks += copies; selectedMarkIDs = Set(copies.map(\.id)); selectedMarkID = copies.last?.id
    }
    func reorderSelected(front: Bool) {
        guard !selectedMarkIDs.isEmpty else { return }
        checkpoint(marks)
        let chosen = marks.filter { selectedMarkIDs.contains($0.id) }, others = marks.filter { !selectedMarkIDs.contains($0.id) }
        marks = front ? others + chosen : chosen + others
    }
    func nudgeSelected(x: CGFloat, y: CGFloat) {
        let original = marks
        moveSelected(from: original, by: CGPoint(x: x / CGFloat(self.original.width), y: y / CGFloat(self.original.height)))
        commitMove(from: original)
    }
    @MainActor func cancelArrangement() {
        arrangementToken = UUID(); arrangementWorker?.cancel(); arrangementWorker = nil; arrangingMarks = false
    }
    @MainActor func arrangeSelected(_ operation: AnnotationArrangement) async {
        guard !preparingPixels else { arrangementError = L10n.text("请先完成或取消当前像素处理。"); return }
        let selected = marks.filter { selectedMarkIDs.contains($0.id) }
        guard selected.count >= 2 else { return }
        cancelArrangement(); arrangingMarks = true; arrangementError = nil
        let token = arrangementToken, revision = renderRevision, source = original, originalMarks = marks
        let owner = presentationWindow
        let boxes = selected.map { mark -> CGRect in
            let points = geometryPoints(mark)
            let x = points.map(\.x).min() ?? 0, y = points.map(\.y).min() ?? 0
            return CGRect(x: x, y: y, width: (points.map(\.x).max() ?? x) - x, height: (points.map(\.y).max() ?? y) - y)
        }
        let deltas = AnnotationLayout.translations(boxes, operation: operation)
        let offsets = Dictionary(uniqueKeysWithValues: zip(selected.map(\.id), deltas))
        let worker = Task.detached(priority: .userInitiated) {
            let snapshot = AnnotationDocument(image: source)
            return try originalMarks.map { mark -> Annotation in
                try Task.checkCancellation()
                guard let delta = offsets[mark.id], delta != .zero else { return mark }
                var updated = mark; updated.points = mark.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
                guard updated.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { throw CaptureError.message(L10n.text("对齐结果超出画布，未移动标注。")) }
                return try snapshot.preparedRequired(updated)
            }
        }
        arrangementWorker = worker
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            beforeArrangementCommitForDiagnostics?()
            guard !Task.isCancelled, token == arrangementToken else { return }
            defer { arrangingMarks = false; arrangementWorker = nil }
            guard revision == renderRevision, Set(selected.map(\.id)) == selectedMarkIDs,
                  owner == nil || owner?.isVisible == true else { arrangementError = L10n.text("画面或选择已改变，或窗口已关闭，未应用旧布局。"); return }
            if zip(originalMarks, result).contains(where: { $0.points != $1.points }) { checkpoint(originalMarks); marks = result }
        } catch { if token == arrangementToken { arrangingMarks = false; arrangementWorker = nil; arrangementError = error.localizedDescription } }
    }
    @discardableResult
    func suggestSensitiveRedactions() -> Int {
        let matches = ocrLines.filter { !SensitiveContent.kinds(in: $0.text).isEmpty }
        return redactOCRLines(matches)
    }
    @discardableResult
    func redactOCRLines(_ matches: [OCRLine]) -> Int {
        guard !matches.isEmpty else { return 0 }
        if Thread.isMainThread { MainActor.assumeIsolated { LocalUsage.shared.record("content.sensitive") } }
        checkpoint(marks)
        var updated = marks
        for line in matches {
            let paddingX = 3 / CGFloat(original.width), paddingY = 3 / CGFloat(original.height)
            let a = CGPoint(x: max(0, line.bounds.minX - paddingX), y: max(0, line.bounds.minY - paddingY))
            let b = CGPoint(x: min(1, line.bounds.maxX + paddingX), y: min(1, line.bounds.maxY + paddingY))
            updated.append(makeMark(tool: .redact, points: [a, b]))
        }
        marks = updated
        return matches.count
    }
    private func geometryPoints(_ mark: Annotation) -> [CGPoint] {
        if let point = mark.points.first, mark.tool == .text {
            let font = mark.fontName.flatMap { NSFont(name: $0, size: mark.fontSize) } ?? (mark.textStyle == .code ? NSFont.monospacedSystemFont(ofSize: mark.fontSize, weight: .medium) : NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold))
            let size = (mark.text as NSString).size(withAttributes: [.font: font])
            let pad: CGFloat = mark.textStyle == .label || mark.textStyle == .callout ? 7 : 0
            return [CGPoint(x: point.x - pad / CGFloat(original.width), y: point.y - pad / CGFloat(original.height)),
                    CGPoint(x: point.x + (size.width + pad) / CGFloat(original.width), y: point.y + (size.height + pad) / CGFloat(original.height))]
        }
        if let point = mark.points.first, mark.tool == .step {
            let r = max(16, mark.fontSize * 0.75)
            return [CGPoint(x: point.x - r / CGFloat(original.width), y: point.y - r / CGFloat(original.height)),
                    CGPoint(x: point.x + r / CGFloat(original.width), y: point.y + r / CGFloat(original.height))]
        }
        guard mark.tool == .curvedArrow, let a = mark.points.first, let b = mark.points.last else { return mark.points }
        let aspect = CGFloat(original.width) / CGFloat(original.height)
        let control = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * mark.curvature / aspect,
                              y: (a.y + b.y) / 2 + (b.x - a.x) * mark.curvature * aspect)
        let path = CGMutablePath(); path.move(to: a); path.addQuadCurve(to: b, control: control)
        let bounds = path.boundingBoxOfPath
        return [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
    }
    func selectionBounds(in rect: CGRect) -> CGRect? {
        guard let mark = selectedMark, !mark.points.isEmpty else { return nil }
        let geometry = marks.filter { selectedMarkIDs.contains($0.id) }.flatMap { geometryPoints($0) }
        let xs = geometry.map(\.x), ys = geometry.map(\.y)
        return CGRect(x: rect.minX + (xs.min() ?? 0) * rect.width,
                      y: rect.minY + (ys.min() ?? 0) * rect.height,
                      width: max(4, ((xs.max() ?? 0) - (xs.min() ?? 0)) * rect.width),
                      height: max(4, ((ys.max() ?? 0) - (ys.min() ?? 0)) * rect.height)).insetBy(dx: -5, dy: -5)
    }
    func render() -> CGImage? {
        commitPendingText?()
        if marks.isEmpty { return original }
        guard let ctx = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        ctx.draw(original, in: rect)
        Self.draw(marks, in: ctx, rect: rect, pixelWidth: CGFloat(original.width), source: original)
        return ctx.makeImage()
    }

    static func draw(_ marks: [Annotation], in context: CGContext, rect: CGRect, pixelWidth: CGFloat, source: CGImage? = nil) {
        context.saveGState(); context.clip(to: rect)
        context.setLineCap(.round); context.setLineJoin(.round)
        let scale = rect.width / pixelWidth
        for mark in marks {
            let points = mark.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            guard let first = points.first, let last = points.last else { continue }
            let area = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
            let lineWidth = mark.width * scale
            context.setLineWidth(lineWidth); context.setStrokeColor(mark.color.cgColor)
            switch mark.tool {
            case .redact: context.setFillColor(NSColor.black.cgColor); context.fill(area)
            case .rectangle, .roundedRectangle, .ellipse:
                context.beginPath()
                if mark.tool == .ellipse { context.addEllipse(in: area) }
                else if mark.tool == .roundedRectangle {
                    let radius = min(18 * scale, min(area.width, area.height) * 0.25)
                    context.addPath(CGPath(roundedRect: area, cornerWidth: radius, cornerHeight: radius, transform: nil))
                } else { context.addRect(area) }
                switch mark.fill {
                case .outline: context.strokePath()
                case .solid: context.setFillColor(mark.color.cgColor); context.fillPath()
                case .translucent:
                    context.setFillColor(mark.color.withAlphaComponent(0.22).cgColor)
                    context.drawPath(using: .fillStroke)
                }
            case .highlight: context.setFillColor(mark.color.withAlphaComponent(0.28).cgColor); context.fill(area)
            case .text: drawStyledText(mark, at: first, scale: scale, context: context)
            case .erase, .replace:
                if let patch = mark.overlayImage { context.interpolationQuality = .high; context.draw(patch, in: area) }
                else { context.setFillColor(NSColor.systemTeal.withAlphaComponent(0.3).cgColor); context.fill(area) }
                if mark.tool == .replace {
                    drawStyledText(mark, at: CGPoint(x: area.minX + 2 * scale, y: area.minY + 2 * scale), scale: scale, context: context)
                }
            case .image:
                if let image = mark.overlayImage {
                    context.saveGState(); context.setAlpha(mark.opacity); context.interpolationQuality = .high
                    context.draw(image, in: area); context.restoreGState()
                }
            case .step:
                let radius = max(16, mark.fontSize * 0.75) * scale
                context.setFillColor(mark.color.cgColor)
                context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
                let number = String(mark.number), size = mark.fontSize * scale
                let width = (number as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold)]).width
                drawText(number, at: CGPoint(x: first.x - width / 2, y: first.y - size * 0.58), size: size, color: .white, context: context)
            case .mosaic:
                guard let source, area.width > 0, area.height > 0 else { continue }
                drawMosaic(mark, source: source, in: area, context: context, scale: scale)
            case .spotlight:
                context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
                context.beginPath(); context.addRect(rect); context.addRect(area)
                context.drawPath(using: .eoFill)
                context.setStrokeColor(mark.color.cgColor); context.setLineWidth(max(1, lineWidth))
                context.stroke(area)
            case .magnify:
                guard let source, area.width > 4, area.height > 4,
                      let a = mark.points.first, let b = mark.points.last else { continue }
                let factor = max(1.2, mark.mosaicStrength)
                let cropWidth = max(1, abs(a.x - b.x) * CGFloat(source.width) / factor)
                let cropHeight = max(1, abs(a.y - b.y) * CGFloat(source.height) / factor)
                let centerX = (a.x + b.x) / 2 * CGFloat(source.width)
                let centerY = (1 - (a.y + b.y) / 2) * CGFloat(source.height)
                let cropRect = CGRect(x: min(max(0, centerX - cropWidth / 2), CGFloat(source.width) - cropWidth),
                                      y: min(max(0, centerY - cropHeight / 2), CGFloat(source.height) - cropHeight),
                                      width: cropWidth, height: cropHeight).integral
                guard let crop = source.cropping(to: cropRect) else { continue }
                context.saveGState(); context.addEllipse(in: area); context.clip()
                context.interpolationQuality = .high; context.draw(crop, in: area); context.restoreGState()
                context.setStrokeColor(mark.color.cgColor); context.setLineWidth(max(2, lineWidth))
                context.strokeEllipse(in: area)
            case .measure:
                let dx = last.x - first.x, dy = last.y - first.y
                let length = max(1, hypot(dx, dy))
                let normal = CGPoint(x: -dy / length, y: dx / length)
                context.beginPath(); context.move(to: first); context.addLine(to: last)
                let tick = 7 * scale
                for point in [first, last] {
                    context.move(to: CGPoint(x: point.x - normal.x * tick, y: point.y - normal.y * tick))
                    context.addLine(to: CGPoint(x: point.x + normal.x * tick, y: point.y + normal.y * tick))
                }
                context.strokePath()
                let pixelHeight = CGFloat(source?.height ?? Int(pixelWidth * rect.height / rect.width))
                let pixelLength = hypot((mark.points.last!.x - mark.points.first!.x) * pixelWidth,
                                        (mark.points.last!.y - mark.points.first!.y) * pixelHeight)
                let label = "\(Int(pixelLength.rounded())) px"
                drawText(label, at: CGPoint(x: (first.x + last.x) / 2 + 7 * scale,
                                            y: (first.y + last.y) / 2 + 8 * scale),
                         size: max(11, mark.fontSize * scale * 0.6), color: mark.color, context: context)
            case .pen:
                context.beginPath(); context.move(to: first); points.dropFirst().forEach { context.addLine(to: $0) }; context.strokePath()
            case .arrow, .curvedArrow, .line:
                context.beginPath(); context.move(to: first)
                let control = CGPoint(x: (first.x + last.x) / 2 - (last.y - first.y) * mark.curvature,
                                      y: (first.y + last.y) / 2 + (last.x - first.x) * mark.curvature)
                if mark.tool == .curvedArrow { context.addQuadCurve(to: last, control: control) }
                else { context.addLine(to: last) }
                if mark.tool != .line {
                    let tangent = mark.tool == .curvedArrow ? control : first
                    let angle = atan2(last.y - tangent.y, last.x - tangent.x), length = lineWidth * 4
                    for delta in [CGFloat.pi / 6, -CGFloat.pi / 6] {
                        context.move(to: last); context.addLine(to: CGPoint(x: last.x - length * cos(angle + delta), y: last.y - length * sin(angle + delta)))
                    }
                }
                context.strokePath()
            case .icon: drawIcon(mark.icon, in: area, color: mark.color, context: context)
            }
        }
        context.restoreGState()
    }
    private static func drawMosaic(_ mark: Annotation, source: CGImage, in area: CGRect, context: CGContext, scale: CGFloat) {
        guard let a = mark.points.first, let b = mark.points.last else { return }
        let crop = CGRect(x: min(a.x, b.x) * CGFloat(source.width), y: (1 - max(a.y, b.y)) * CGFloat(source.height),
                          width: abs(a.x - b.x) * CGFloat(source.width), height: abs(a.y - b.y) * CGFloat(source.height)).integral
        guard let image = source.cropping(to: crop) else { return }
        let cell = max(8, Int(7 + mark.mosaicStrength * 7))
        let w = max(1, image.width / cell), h = max(1, image.height / cell)
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = small.makeImage() else { return }
        context.saveGState()
        context.clip(to: area)
        switch mark.mosaicStyle {
        case .pixel:
            context.interpolationQuality = .none
            context.draw(pixels, in: area)
        case .soft:
            context.interpolationQuality = .high
            context.draw(pixels, in: area)
            context.setFillColor(NSColor(calibratedRed: 0.84, green: 0.94, blue: 1, alpha: 0.26).cgColor)
            context.fill(area)
        case .crystal:
            guard let rawData = small.data else { break }
            let data = rawData.assumingMemoryBound(to: UInt8.self)
            let side = max(7 * scale, CGFloat(cell) * scale * 0.9)
            let rowHeight = side * 1.5
            let halfWidth = side * 0.866
            let columns = Int(ceil(area.width / (halfWidth * 2))) + 2
            let rows = Int(ceil(area.height / rowHeight)) + 2
            for row in 0..<rows {
                for column in 0..<columns {
                    let cx = area.minX + CGFloat(column) * halfWidth * 2 + (row.isMultiple(of: 2) ? 0 : halfWidth)
                    let cy = area.minY + CGFloat(row) * rowHeight
                    let px = min(w - 1, max(0, Int((cx - area.minX) / area.width * CGFloat(w))))
                    let py = min(h - 1, max(0, Int((cy - area.minY) / area.height * CGFloat(h))))
                    let offset = (py * w + px) * 4
                    context.setFillColor(CGColor(red: CGFloat(data[offset]) / 255, green: CGFloat(data[offset + 1]) / 255,
                                                 blue: CGFloat(data[offset + 2]) / 255, alpha: 1))
                    let path = CGMutablePath()
                    for i in 0..<6 {
                        let angle = CGFloat(i) * .pi / 3 + .pi / 6
                        let point = CGPoint(x: cx + side * cos(angle), y: cy + side * sin(angle))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath(); context.addPath(path); context.fillPath()
                    context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
                    context.setLineWidth(max(0.5, scale)); context.addPath(path); context.strokePath()
                }
            }
        case .stripe:
            context.interpolationQuality = .none
            context.draw(pixels, in: area)
            context.setFillColor(NSColor(calibratedRed: 0.035, green: 0.11, blue: 0.19, alpha: 0.62).cgColor)
            context.fill(area)
            let spacing = max(6, CGFloat(cell) * scale * 0.58)
            context.setLineWidth(max(2, spacing * 0.26))
            for (index, x) in stride(from: area.minX - area.height, through: area.maxX + area.height, by: spacing).enumerated() {
                context.setStrokeColor(NSColor(calibratedRed: 0.28, green: 0.83, blue: 0.94,
                                               alpha: index.isMultiple(of: 4) ? 0.7 : 0.28).cgColor)
                context.move(to: CGPoint(x: x, y: area.minY)); context.addLine(to: CGPoint(x: x + area.height, y: area.maxY)); context.strokePath()
            }
        }
        context.restoreGState()
    }

    private static func drawIcon(_ icon: VectorIcon, in area: CGRect, color: NSColor, context: CGContext) {
        guard area.width > 0, area.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: area.minX, y: area.minY)
        context.scaleBy(x: area.width, y: area.height)
        context.setFillColor(color.cgColor); context.setStrokeColor(color.cgColor)
        context.setLineCap(.round); context.setLineJoin(.round)
        let path = CGMutablePath()
        switch icon {
        case .star, .sparkle:
            let count = icon == .star ? 5 : 4
            for i in 0..<(count * 2) {
                let angle = CGFloat(i) * .pi / CGFloat(count) + .pi / 2
                let radius: CGFloat = i.isMultiple(of: 2) ? 0.48 : (icon == .star ? 0.21 : 0.11)
                let point = CGPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        case .heart:
            path.move(to: CGPoint(x: 0.5, y: 0.08))
            path.addCurve(to: CGPoint(x: 0.04, y: 0.6), control1: CGPoint(x: 0.18, y: 0.35), control2: CGPoint(x: 0.01, y: 0.35))
            path.addCurve(to: CGPoint(x: 0.5, y: 0.92), control1: CGPoint(x: 0.05, y: 0.92), control2: CGPoint(x: 0.34, y: 1.02))
            path.addCurve(to: CGPoint(x: 0.96, y: 0.6), control1: CGPoint(x: 0.66, y: 1.02), control2: CGPoint(x: 0.95, y: 0.92))
            path.addCurve(to: CGPoint(x: 0.5, y: 0.08), control1: CGPoint(x: 0.99, y: 0.35), control2: CGPoint(x: 0.82, y: 0.35))
            path.closeSubpath()
        case .check:
            path.move(to: CGPoint(x: 0.08, y: 0.52)); path.addLine(to: CGPoint(x: 0.38, y: 0.23)); path.addLine(to: CGPoint(x: 0.92, y: 0.84))
            context.setLineWidth(0.14); context.addPath(path); context.strokePath(); context.restoreGState(); return
        case .bolt:
            [CGPoint(x: 0.57, y: 0.98), CGPoint(x: 0.19, y: 0.46), CGPoint(x: 0.47, y: 0.48),
             CGPoint(x: 0.4, y: 0.02), CGPoint(x: 0.85, y: 0.59), CGPoint(x: 0.56, y: 0.56)].enumerated().forEach {
                if $0.offset == 0 { path.move(to: $0.element) } else { path.addLine(to: $0.element) }
            }; path.closeSubpath()
        case .warning:
            path.move(to: CGPoint(x: 0.5, y: 0.96)); path.addLine(to: CGPoint(x: 0.03, y: 0.12)); path.addLine(to: CGPoint(x: 0.97, y: 0.12)); path.closeSubpath()
        case .pin:
            path.addEllipse(in: CGRect(x: 0.12, y: 0.28, width: 0.76, height: 0.7))
            path.move(to: CGPoint(x: 0.5, y: 0.02)); path.addLine(to: CGPoint(x: 0.25, y: 0.39)); path.addLine(to: CGPoint(x: 0.75, y: 0.39)); path.closeSubpath()
        case .cursor:
            path.move(to: CGPoint(x: 0.08, y: 0.96)); path.addLine(to: CGPoint(x: 0.16, y: 0.05)); path.addLine(to: CGPoint(x: 0.37, y: 0.36))
            path.addLine(to: CGPoint(x: 0.68, y: 0.08)); path.addLine(to: CGPoint(x: 0.86, y: 0.28))
            path.addLine(to: CGPoint(x: 0.55, y: 0.56)); path.addLine(to: CGPoint(x: 0.88, y: 0.76)); path.closeSubpath()
        }
        context.addPath(path); context.fillPath()
        if icon == .warning {
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.75).cgColor); context.setLineWidth(0.075)
            context.move(to: CGPoint(x: 0.5, y: 0.38)); context.addLine(to: CGPoint(x: 0.5, y: 0.68)); context.strokePath()
            context.fillEllipse(in: CGRect(x: 0.462, y: 0.22, width: 0.076, height: 0.076))
        }
        if icon == .pin {
            context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            context.fillEllipse(in: CGRect(x: 0.39, y: 0.57, width: 0.22, height: 0.22))
        }
        context.restoreGState()
    }
    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor, context: CGContext) {
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: max(1, size), weight: .semibold), .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }
    private static func drawStyledText(_ mark: Annotation, at point: CGPoint, scale: CGFloat, context: CGContext) {
        let size = max(1, mark.fontSize * scale)
        if let offset = mark.textOriginOffset, let name = mark.fontName, mark.tool == .replace {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(name as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): mark.color.cgColor,
                NSAttributedString.Key(kCTKernAttributeName as String): (mark.fontTracking ?? 0)*scale]
            context.saveGState(); context.textMatrix = .identity
            context.textPosition = CGPoint(x: point.x+offset.x*scale, y: point.y+offset.y*scale)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: mark.text, attributes: attributes)), context)
            context.restoreGState(); return
        }
        let font = mark.fontName.flatMap { NSFont(name: $0, size: size) } ?? (mark.textStyle == .code ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium) : NSFont.systemFont(ofSize: size, weight: .semibold))
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: mark.color]
        let measured = (mark.text as NSString).size(withAttributes: attributes)
        var origin = point
        if mark.textStyle == .label || mark.textStyle == .callout {
            let padding = 7 * scale
            let box = CGRect(x: point.x - padding, y: point.y - padding, width: measured.width + 2 * padding, height: measured.height + 2 * padding)
            context.setFillColor(mark.color.cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil)); context.fillPath()
            if mark.textStyle == .callout {
                context.move(to: CGPoint(x: box.minX + 12 * scale, y: box.minY + 1))
                context.addLine(to: CGPoint(x: box.minX + 8 * scale, y: box.minY - 10 * scale))
                context.addLine(to: CGPoint(x: box.minX + 28 * scale, y: box.minY + 1)); context.closePath(); context.fillPath()
            }
            let rgb = mark.color.usingColorSpace(.deviceRGB) ?? .black
            let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            attributes[.foregroundColor] = luminance > 0.6 ? NSColor.black : NSColor.white
        } else if mark.textStyle == .outlined {
            attributes[.strokeColor] = NSColor.black.withAlphaComponent(0.75); attributes[.strokeWidth] = -3
        }
        if mark.tool == .replace { origin.y = point.y }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (mark.text as NSString).draw(at: origin, withAttributes: attributes); NSGraphicsContext.restoreGraphicsState()
    }
}

final class AnnotationCanvas: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        clearSnapGuides()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if window != nil && newWindow !== window { document.cancelPixelPreparation() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); document.presentationWindow = window
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.clearSnapGuides()
            }
        }
    }
    let document: AnnotationDocument
    var imageDisplayScale: CGFloat?
    var transparentOverlay = false
    var onEscape: (() -> Void)?
    private var current: Annotation?
    private var observer: Any?
    private var textEditor: TextAnnotationEditor?
    private var imageResizeCorner: Int?
    private var markDragStart: CGPoint?
    private var markDragOriginal: [Annotation]?
    private(set) var snapGuides: [AnnotationSnapGuide] = []
    private func clearSnapGuides() {
        guard !snapGuides.isEmpty else { return }
        snapGuides = []; needsDisplay = true
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override var acceptsFirstResponder: Bool { true }
    private var imageRect: CGRect {
        let area = transparentOverlay ? bounds : bounds.insetBy(dx: 24, dy: 24)
        let ratio = imageDisplayScale ?? min(area.width / CGFloat(document.original.width), area.height / CGFloat(document.original.height))
        let size = CGSize(width: CGFloat(document.original.width) * ratio, height: CGFloat(document.original.height) * ratio)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    init(document: AnnotationDocument) {
        self.document = document; super.init(frame: .zero)
        document.commitPendingText = { [weak self] in self?.textEditor?.commit() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: document.selectingMark ? .openHand : .crosshair)
        if document.selectingMark {
            for point in document.imageResizeHandles(in: imageRect) {
                addCursorRect(CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16), cursor: .crosshair)
            }
        }
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), r = imageRect
        return CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)), y: min(1, max(0, (p.y - r.minY) / r.height)))
    }
    override func mouseDown(with event: NSEvent) {
        clearSnapGuides()
        guard !document.preparingPixels, !document.replacingOCR, !document.arrangingMarks else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if document.selectingMark, !event.modifierFlags.contains(.shift),
           let corner = document.imageResizeHandle(at: viewPoint, in: imageRect) {
            window?.makeFirstResponder(self)
            imageResizeCorner = corner
            markDragStart = CGPoint(x: (viewPoint.x - imageRect.minX) / imageRect.width,
                                    y: (viewPoint.y - imageRect.minY) / imageRect.height)
            markDragOriginal = document.marks
            needsDisplay = true; return
        }
        guard imageRect.contains(viewPoint) else { return }
        window?.makeFirstResponder(self)
        if document.selectingMark {
            let location = point(event)
            document.selectMark(at: location, tolerance: CGPoint(x: 8 / imageRect.width, y: 8 / imageRect.height), additive: event.modifierFlags.contains(.shift))
            markDragStart = location; markDragOriginal = document.selectedMark == nil ? nil : document.marks
            needsDisplay = true; return
        }
        if document.tool == .step { document.addOnCanvas(document.makeMark(tool: .step, points: [point(event)])); needsDisplay = true; return }
        if document.tool == .text {
            let normalized = point(event), location = convert(event.locationInWindow, from: nil)
            textEditor = TextAnnotationEditor(in: self, at: location, fontSize: 16, color: document.color.color) { [weak self] text in
                guard let self else { return }
                if !text.isEmpty { self.document.addOnCanvas(self.document.makeMark(tool: .text, points: [normalized], text: text)) }
                self.textEditor = nil; self.needsDisplay = true
            }
            return
        }
        current = document.makeMark(tool: document.tool, points: [point(event), point(event)])
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if document.selectingMark, let start = markDragStart, let original = markDragOriginal {
            let location = convert(event.locationInWindow, from: nil)
            let delta = CGPoint(x: (location.x - imageRect.minX) / imageRect.width - start.x,
                                y: (location.y - imageRect.minY) / imageRect.height - start.y)
            if let corner = imageResizeCorner {
                document.resizeSelectedImage(from: original, corner: corner, by: delta)
            } else { snapGuides = document.moveSelected(from: original, by: delta, snapTolerance: CGSize(width: 6 / imageRect.width, height: 6 / imageRect.height)) }
            needsDisplay = true; return
        }
        guard var mark = current else { return }
        if mark.tool == .pen { mark.points.append(point(event)) }
        else if mark.tool == .icon { mark.points[1] = document.iconEnd(from: mark.points[0], toward: point(event)) }
        else { mark.points[1] = point(event) }
        current = mark; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { clearSnapGuides() }
        if document.selectingMark {
            if let original = markDragOriginal { document.commitMoveOnCanvas(from: original) }
            markDragStart = nil; markDragOriginal = nil; imageResizeCorner = nil; needsDisplay = true; return
        }
        guard let current else { return }
        let completed = document.finishIcon(current)
        let first = completed.points.first!, last = completed.points.last!
        if hypot(last.x - first.x, last.y - first.y) > 0.001 || completed.points.count > 2 { document.addOnCanvas(completed) }
        self.current = nil; needsDisplay = true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), !(window?.firstResponder is NSTextView) else { return super.performKeyEquivalent(with: event) }
        clearSnapGuides()
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": if event.modifierFlags.contains(.shift) { document.redo() } else { document.undo() }
        case "a": document.selectingMark = true; document.selectAllMarks()
        case "d": document.duplicateSelectedOnCanvas()
        default: return super.performKeyEquivalent(with: event)
        }
        needsDisplay = true; return true
    }
    override func keyDown(with event: NSEvent) {
        clearSnapGuides()
        if event.keyCode == 53, let onEscape { onEscape(); return }
        if document.selectingMark {
            if event.keyCode == 51 || event.keyCode == 117 { document.deleteSelected(); needsDisplay = true; return }
            if [123, 124, 125, 126].contains(event.keyCode) {
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                document.nudgeOnCanvas(x: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                       y: event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0)
                needsDisplay = true; return
            }
        }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        if transparentOverlay { NSGraphicsContext.current?.cgContext.clear(bounds) }
        if !transparentOverlay { StudioNativeColor.canvas.setFill(); bounds.fill() }
        // Checkerboard makes transparent window captures explicit.
        let r = imageRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        let visibleImage = r.intersection(dirtyRect)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if !transparentOverlay, !visibleImage.isNull { for y in stride(from: r.minY + floor((visibleImage.minY - r.minY) / 14) * 14, to: visibleImage.maxY, by: 14) {
            for x in stride(from: r.minX + floor((visibleImage.minX - r.minX) / 14) * 14, to: visibleImage.maxX, by: 14) {
                let alternate = (Int((x - r.minX) / 14) + Int((y - r.minY) / 14)) % 2 == 0
                NSColor(white: dark ? (alternate ? 0.16 : 0.20) : (alternate ? 0.99 : 0.94), alpha: 1).setFill()
                CGRect(x: x, y: y, width: 14, height: 14).fill()
            }
        }
        }
        NSImage(cgImage: document.original, size: r.size).draw(in: r)
        if let context = NSGraphicsContext.current?.cgContext {
            AnnotationDocument.draw(document.marks + (current.map { [$0] } ?? []), in: context, rect: r, pixelWidth: CGFloat(document.original.width), source: document.original)
        }
        if let selected = document.selectionBounds(in: r) {
            (transparentOverlay ? NSColor(calibratedRed: 0.3, green: 0.91, blue: 0.97, alpha: 1) : StudioNativeColor.accent).setStroke()
            let focus = NSBezierPath(roundedRect: selected, xRadius: 4, yRadius: 4)
            focus.lineWidth = 1.4; focus.setLineDash([4, 3], count: 2, phase: 0); focus.stroke()
        }
        document.drawImageResizeHandles(in: r)
        if document.selectingMark, document.snapsAnnotations, markDragOriginal != nil,
           let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setLineDash(phase: 0, lengths: [4, 3])
            for guide in snapGuides where guide.position.isFinite && (0...1).contains(guide.position) {
                let start: CGPoint, end: CGPoint
                if guide.axis == .vertical {
                    let x = r.minX + guide.position * r.width
                    start = CGPoint(x: x, y: r.minY); end = CGPoint(x: x, y: r.maxY)
                } else {
                    let y = r.minY + guide.position * r.height
                    start = CGPoint(x: r.minX, y: y); end = CGPoint(x: r.maxX, y: y)
                }
                for (color, width) in [(NSColor.black.withAlphaComponent(0.45), CGFloat(2.5)), (NSColor.systemPink, CGFloat(1))] {
                    context.setStrokeColor(color.cgColor); context.setLineWidth(width)
                    context.beginPath(); context.move(to: start); context.addLine(to: end); context.strokePath()
                }
            }
            context.restoreGState()
        }
        if document.showsOCRLocations {
            NSColor(calibratedRed: 0.23, green: 0.84, blue: 0.94, alpha: 0.95).setStroke()
            for line in document.ocrLines {
                let box = CGRect(x: r.minX + line.bounds.minX * r.width,
                                 y: r.minY + line.bounds.minY * r.height,
                                 width: line.bounds.width * r.width, height: line.bounds.height * r.height)
                let outline = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
                outline.lineWidth = 1; outline.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
