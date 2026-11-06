import AppKit
import SwiftUI
import Vision
import CoreImage

enum ImageStripAxis: String, CaseIterable, Identifiable {
    case rows, columns
    var id: Self { self }
    var title: String { self == .rows ? L10n.text("横条（缩短高度）") : L10n.text("竖条（缩短宽度）") }
}

struct ImageStrip: Identifiable, Equatable {
    let id = UUID()
    let axis: ImageStripAxis
    let start: Int
    let end: Int
}

struct ImageCleanupPlan: Equatable {
    var crop: CGRect?
    var strips: [ImageStrip] = []
    var trim = false
    var removeBackground = false
    var tolerance = 8
}

enum CaptureImageCleanup {
    // All positions refer to the original image, from its top or left edge.
    // Overlapping ranges are merged so repeated selection cannot delete twice.
    static func keptRanges(length: Int, strips: [ImageStrip], axis: ImageStripAxis) throws -> [Range<Int>] {
        let sorted = strips.filter { $0.axis == axis }.sorted { $0.start < $1.start }
        guard sorted.allSatisfy({ $0.start >= 0 && $0.end <= length && $0.end > $0.start }) else {
            throw CaptureError.message(L10n.text("删段范围必须位于原图内，结束位置大于起点。"))
        }
        var cursor = 0, kept: [Range<Int>] = []
        for strip in sorted {
            if strip.start > cursor { kept.append(cursor..<strip.start) }
            cursor = max(cursor, strip.end)
        }
        if cursor < length { kept.append(cursor..<length) }
        guard !kept.isEmpty else { throw CaptureError.message(L10n.text("请至少保留一行和一列像素。")) }
        return kept
    }

    static func shorten(_ image: CGImage, strips: [ImageStrip]) throws -> CGImage {
        guard strips.count <= 100 else { throw CaptureError.message(L10n.text("一次最多删除 100 段。")) }
        try validate(image)
        let rows = try keptRanges(length: image.height, strips: strips, axis: .rows)
        let columns = try keptRanges(length: image.width, strips: strips, axis: .columns)
        if strips.isEmpty { return image }
        let width = columns.reduce(0) { $0 + $1.count }, height = rows.reduce(0) { $0 + $1.count }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("无法分配删段图片，请减少图片尺寸。"))
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        var y = 0
        for row in rows {
            var x = 0
            for column in columns {
                try Task.checkCancellation()
                guard let tile = image.cropping(to: CGRect(x: column.lowerBound, y: row.lowerBound,
                                                          width: column.count, height: row.count)) else {
                    throw CaptureError.message(L10n.text("无法读取删段区域。"))
                }
                context.draw(tile, in: CGRect(x: x, y: height - y - row.count, width: column.count, height: row.count))
                x += column.count
            }
            y += row.count
        }
        guard let result = context.makeImage() else { throw CaptureError.message(L10n.text("删段拼合失败。")) }
        return result
    }

    static func trim(_ image: CGImage, tolerance: Int = 8) throws -> CGImage {
        try validate(image)
        guard (0...64).contains(tolerance) else { throw CaptureError.message(L10n.text("留白容差必须在 0–64 内。")) }
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else {
            throw CaptureError.message(L10n.text("无法读取图片边缘。"))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let corners = [0, (width - 1) * 4, (height - 1) * width * 4, (height * width - 1) * 4]
        let transparent = corners.allSatisfy { bytes[$0 + 3] <= 2 }
        func background(_ index: Int) -> Bool {
            if transparent { return bytes[index + 3] <= 2 }
            return (0..<4).allSatisfy { abs(Int(bytes[index + $0]) - Int(bytes[$0])) <= tolerance }
        }
        guard corners.allSatisfy(background) else {
            throw CaptureError.message(L10n.text("四角背景不一致，请先手动删段或去背景。"))
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            if y % 64 == 0 { try Task.checkCancellation() }
            for x in 0..<width where !background((y * width + x) * 4) {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { throw CaptureError.message(L10n.text("没有发现需要保留的内容。")) }
        guard let result = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
            throw CaptureError.message(L10n.text("裁掉留白失败。"))
        }
        return result
    }

    static func foreground(_ image: CGImage, instances: IndexSet? = nil) throws -> CGImage {
        try validate(image)
        guard Double(image.width) * Double(image.height) <= 20_000_000 else {
            throw CaptureError.message(L10n.text("主体去背景支持最多 2000 万像素；请先缩小图片。"))
        }
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CaptureError.message(L10n.text("没有识别到明确主体，请使用手动删段。"))
        }
        let chosen = instances ?? observation.allInstances
        guard !chosen.isEmpty, chosen.isSubset(of: observation.allInstances) else { throw CaptureError.message(L10n.text("所选主体不在当前图片中，请重新识别。")) }
        let buffer = try observation.generateMaskedImage(ofInstances: chosen, from: handler,
                                                          croppedToInstancesExtent: false)
        try Task.checkCancellation()
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(masked, from: masked.extent),
              result.width == image.width, result.height == image.height else {
            throw CaptureError.message(L10n.text("主体去背景未生成完整尺寸图片。"))
        }
        return result
    }

    static func render(_ image: CGImage, plan: ImageCleanupPlan) throws -> CGImage {
        try validate(image)
        guard plan.strips.count <= 100 else { throw CaptureError.message(L10n.text("一次最多删除 100 段。")) }
        _ = try keptRanges(length: image.height, strips: plan.strips, axis: .rows)
        _ = try keptRanges(length: image.width, strips: plan.strips, axis: .columns)
        let size = CGSize(width: image.width, height: image.height)
        let crop = plan.crop ?? CGRect(origin: .zero, size: size)
        guard ImageCropGeometry.bounded(crop, size: size) == crop,
              let cropped = image.cropping(to: crop) else {
            throw CaptureError.message(L10n.text("裁剪范围必须位于原图内，并至少保留一个像素。"))
        }
        try Task.checkCancellation()
        var result = try shorten(cropped, strips: ImageCropGeometry.translatedStrips(plan.strips, crop: crop))
        if plan.removeBackground { result = try foreground(result) }
        if plan.trim { result = try trim(result, tolerance: plan.tolerance) }
        try Task.checkCancellation()
        return result
    }
    private static func validate(_ image: CGImage) throws {
        guard max(image.width, image.height) <= 60_000, Double(image.width) * Double(image.height) <= 80_000_000 else {
            throw CaptureError.message(L10n.text("图片超过 60000 边长或 8000 万像素处理上限。"))
        }
    }
}

private actor ImageCleanupProcessor {
    // Cancellation cannot interrupt every Vision operation. Serializing jobs
    // prevents a burst of crop changes from running multiple full-size masks.
    func render(_ source: CGImage, plan: ImageCleanupPlan) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool { try CaptureImageCleanup.render(source, plan: plan) }
    }
}

@MainActor
final class ImageCleanupModel: ObservableObject {
    let source: CGImage
    @Published private(set) var result: CGImage?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let processor = ImageCleanupProcessor()
    init(source: CGImage) { self.source = source; result = source }
    func update(_ plan: ImageCleanupPlan) {
        cancel()
        let token = generation, image = source, processor = self.processor
        busy = true; result = nil; error = nil
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) { try await processor.render(image, plan: plan) }
                let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                result = output; busy = false; task = nil
            } catch is CancellationError { }
            catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription; busy = false; task = nil
            }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false; result = nil }
}

struct ImageCleanupView: View {
    @StateObject private var model: ImageCleanupModel
    let copy: (CGImage) -> Void
    let save: (CGImage) -> Void
    let close: () -> Void
    var edit: ((CGImage) async throws -> Void)?
    @State private var delivering = false
    @State private var deliveryTask: Task<Void, Never>?
    @State private var undoPlans: [ImageCleanupPlan] = []
    @State private var redoPlans: [ImageCleanupPlan] = []
    @State private var restoringPlan = false
    @State private var selectionMode = ImageCleanupSelection.crop
    @State private var zoom: CGFloat?
    @State private var plan = ImageCleanupPlan()
    @State private var axis = ImageStripAxis.rows
    @State private var start = 0
    @State private var end = 1
    @State private var showSource = true
    @State private var selectionError: String?
    @State private var showRepairStudio = false
    @State private var showSimplification = false
    @State private var showSmartComposition = false
    @State private var showColorAnalysis = false
    init(source: CGImage, copy: @escaping (CGImage) -> Void, save: @escaping (CGImage) -> Void, close: @escaping () -> Void, edit: ((CGImage) async throws -> Void)? = nil) {
        self.init(model: ImageCleanupModel(source: source), copy: copy, save: save, close: close, edit: edit)
    }
    init(model: ImageCleanupModel, copy: @escaping (CGImage) -> Void, save: @escaping (CGImage) -> Void, close: @escaping () -> Void, edit: ((CGImage) async throws -> Void)? = nil) {
        _model = StateObject(wrappedValue: model)
        self.copy = copy; self.save = save; self.close = close; self.edit = edit
    }
    var body: some View {
        StudioWorkspace(title: L10n.text("裁剪与清理"), symbol: "crop") {
            Picker(L10n.text("选区工具"), selection: $selectionMode) {
                ForEach(ImageCleanupSelection.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                .onChange(of: selectionMode) { _, _ in showSource = true }
            StudioMenu(zoom == -1 ? L10n.text("宽度") : zoom.map { "\(Int($0 * 100))%" } ?? L10n.text("适应")) {
                Button(L10n.text("适合窗口")) { zoom = nil }
                Button(L10n.text("适合宽度")) { zoom = -1 }
                ForEach([25, 50, 100, 200, 400], id: \.self) { percent in
                    Button("\(percent)%") { zoom = CGFloat(percent) / 100 }
                }
            }.fixedSize().help(L10n.text("预览缩放"))
            StudioMenu(L10n.text("图像工具")) {
                Button(L10n.text("修复与抠图…")) { showRepairStudio = true }
                Button(L10n.text("界面简化…")) { showSimplification = true }
                Button(L10n.text("智能构图…")) { showSmartComposition = true }
                Button(L10n.text("颜色与对比度…")) { showColorAnalysis = true }
            }.disabled(model.busy)
            // ImageCleanupWindow owns cancellation when its native Close is used.
            EmptyView()
        } preview: {
            VStack(spacing: 0) {
                if let image = showSource ? model.source : model.result {
                    ImageCropCanvas(image: image,
                                    sourceSize: CGSize(width: model.source.width, height: model.source.height),
                                    showSource: showSource, mode: selectionMode, axis: axis, strips: plan.strips,
                                    crop: $plan.crop, zoom: zoom) { a, b in start = a; end = b; addStrip() }
                } else if model.busy { ProgressView(L10n.text("正在生成结果…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView(L10n.text("暂无结果"), systemImage: "photo.badge.exclamationmark") }
                HStack {
                    Picker(L10n.text("预览"), selection: $showSource) { Text(L10n.text("原图")).tag(true); Text(L10n.text("结果")).tag(false) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 110).accessibilityIdentifier("cleanup-preview")
                    Spacer()
                    if let image = showSource ? model.source : model.result {
                        Text("\(image.width) × \(image.height) px").monospacedDigit()
                    }
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } inspector: {
            if selectionMode == .crop {
                InspectorGroup(L10n.text("裁剪范围"), initiallyExpanded: true) {
                    HStack(alignment: .top, spacing: 12) {
                        cropField(L10n.text("左边"), keyPath: \.origin.x)
                        cropField(L10n.text("顶部"), keyPath: \.origin.y)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        cropField(L10n.text("宽度"), keyPath: \.size.width)
                        cropField(L10n.text("高度"), keyPath: \.size.height)
                    }
                    Button(L10n.text("保留全图")) { plan.crop = nil; selectionError = nil }
                        .disabled(plan.crop == nil)
                }
            } else {
                InspectorGroup(L10n.text("删除条带"), initiallyExpanded: true) {
                    InspectorField(title: L10n.text("方向")) { Picker(L10n.text("方向"), selection: $axis) { ForEach(ImageStripAxis.allCases) { Text($0.title).tag($0) } }.labelsHidden() }
                        .onChange(of: axis) { _, _ in start = 0; end = 1 }
                    HStack(alignment: .top, spacing: 12) {
                        InspectorField(title: L10n.text("开始像素")) { TextField(L10n.text("开始像素"), value: $start, format: .number).accessibilityLabel(L10n.text("删段起点像素")) }
                        InspectorField(title: L10n.text("结束像素")) { TextField(L10n.text("结束像素"), value: $end, format: .number).accessibilityLabel(L10n.text("删段终点像素（不含）")) }
                    }
                    Button { addStrip() } label: { Label(L10n.text("添加条带"), systemImage: "plus") }.disabled(plan.strips.count >= 100)
                    ForEach(plan.strips) { strip in
                        HStack {
                            Text(L10n.text("\(strip.axis == .rows ? L10n.text("横条") : L10n.text("竖条")) \(strip.start)–\(strip.end) px")).monospacedDigit()
                            Spacer()
                            StudioIconButton(title: L10n.text("移除条带"), symbol: "xmark") { plan.strips.removeAll { $0.id == strip.id } }
                        }
                    }
                }
            }
            InspectorGroup(L10n.text("背景"), initiallyExpanded: false) {
                Toggle(L10n.text("移除背景"), isOn: $plan.removeBackground)
                Toggle(L10n.text("裁掉边缘留白"), isOn: $plan.trim)
                if plan.trim { Stepper(L10n.text("背景容差 \(plan.tolerance)"), value: $plan.tolerance, in: 0...64) }
            }
            if let error = selectionError ?? model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            StudioIconButton(title: L10n.text("撤销"), symbol: "arrow.uturn.backward") { restore(previous: true) }
                .disabled(undoPlans.isEmpty || delivering).keyboardShortcut("z", modifiers: .command)
            StudioIconButton(title: L10n.text("重做"), symbol: "arrow.uturn.forward") { restore(previous: false) }
                .disabled(redoPlans.isEmpty || delivering).keyboardShortcut("z", modifiers: [.command, .shift])
            Button(L10n.text("恢复原图")) { plan = ImageCleanupPlan(); showSource = true; selectionError = nil }
                .disabled(delivering)
            if model.busy { ProgressView().controlSize(.small) }
            Spacer()
            Button(L10n.text("保存副本…")) { if let image = model.result { save(image) } }.disabled(model.busy || model.result == nil || delivering)
            Button(L10n.text("复制图片")) { if let image = model.result { copy(image) } }.disabled(model.busy || model.result == nil || delivering)
            if edit != nil {
                Button(delivering ? L10n.text("正在打开…") : L10n.text("完成并编辑")) { deliverToEditor() }
                    .disabled(model.busy || model.result == nil || delivering).buttonStyle(StudioButtonStyle(primary: true, command: true))
            }
        }
            .disabled(delivering)
            .onChange(of: plan) { old, value in
                selectionError = nil
                if restoringPlan { restoringPlan = false }
                else { undoPlans.append(old); if undoPlans.count > 80 { undoPlans.removeFirst() }; redoPlans.removeAll() }
                deliveryTask?.cancel(); delivering = false
                model.update(value)
            }
            .onDisappear { deliveryTask?.cancel(); model.cancel() }
            .sheet(isPresented: $showRepairStudio) {
                RepairStudioView(image: model.result ?? model.source, save: save, close: { showRepairStudio = false })
            }
            .sheet(isPresented: $showSimplification) {
                UISimplificationView(image: model.result ?? model.source, save: save, close: { showSimplification = false })
            }
            .sheet(isPresented: $showSmartComposition) {
                SmartCompositionView(image: model.result ?? model.source, save: save, close: { showSmartComposition = false })
            }
            .sheet(isPresented: $showColorAnalysis) {
                ColorAnalysisView(image: model.result ?? model.source, close: { showColorAnalysis = false })
            }
    }
    private func cropField(_ title: String, keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        InspectorField(title: title + "（px）") {
            TextField(title, value: Binding<Int>(get: {
                Int((plan.crop ?? CGRect(x: 0, y: 0, width: model.source.width, height: model.source.height))[keyPath: keyPath])
            }, set: { value in
                var rect = plan.crop ?? CGRect(x: 0, y: 0, width: model.source.width, height: model.source.height)
                rect[keyPath: keyPath] = CGFloat(value)
                let size = CGSize(width: model.source.width, height: model.source.height)
                if keyPath == \CGRect.origin.x, rect.minX >= 0, rect.minX < size.width {
                    rect.size.width = min(rect.width, size.width - rect.minX)
                }
                if keyPath == \CGRect.origin.y, rect.minY >= 0, rect.minY < size.height {
                    rect.size.height = min(rect.height, size.height - rect.minY)
                }
                guard ImageCropGeometry.bounded(rect, size: size) == rect else {
                    selectionError = L10n.text("裁剪范围须位于原图内，宽高至少为 1 px。"); return
                }
                plan.crop = rect; selectionError = nil; showSource = true
            }), format: .number).monospacedDigit().disabled(delivering)
        }
    }
    private func restore(previous: Bool) {
        guard previous ? !undoPlans.isEmpty : !redoPlans.isEmpty else { return }
        let value: ImageCleanupPlan
        if previous { value = undoPlans.removeLast(); redoPlans.append(plan) }
        else { value = redoPlans.removeLast(); undoPlans.append(plan) }
        restoringPlan = true; plan = value; selectionError = nil
    }
    private func deliverToEditor() {
        guard let edit, let image = model.result, !model.busy, !delivering else { return }
        delivering = true; selectionError = nil
        deliveryTask = Task { @MainActor in
            do {
                try await edit(image)
                delivering = false; deliveryTask = nil; close()
            } catch is CancellationError { delivering = false; deliveryTask = nil }
            catch { selectionError = L10n.text("无法打开编辑器：\(error.localizedDescription) 处理结果已保留。"); delivering = false; deliveryTask = nil }
        }
    }
    private func addStrip() {
        let length = axis == .rows ? model.source.height : model.source.width
        guard plan.strips.count < 100, start >= 0, end <= length, end > start else {
            selectionError = L10n.text("请输入 0–\(length) 内的范围，结束位置须大于起点。"); return
        }
        let strip = ImageStrip(axis: axis, start: start, end: end)
        do {
            _ = try CaptureImageCleanup.keptRanges(length: length, strips: plan.strips + [strip], axis: axis)
            plan.strips.append(strip); selectionError = nil
        } catch { selectionError = error.localizedDescription }
    }
    static func fittedSize(_ image: CGSize, in available: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    static func stripRect(_ strip: ImageStrip, image: CGSize, fit: CGSize) -> CGRect {
        if strip.axis == .rows {
            return CGRect(x: 0, y: CGFloat(strip.start) / image.height * fit.height,
                          width: fit.width, height: CGFloat(strip.end - strip.start) / image.height * fit.height)
        }
        return CGRect(x: CGFloat(strip.start) / image.width * fit.width, y: 0,
                      width: CGFloat(strip.end - strip.start) / image.width * fit.width, height: fit.height)
    }
}

@MainActor
final class ImageCleanupWindow: NSWindow {
    let model: ImageCleanupModel
    init(source: CGImage) {
        model = ImageCleanupModel(source: source)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 940, height: 680),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = L10n.text("裁剪与清理 — DeskCapture"); isReleasedWhenClosed = false
        contentMinSize = StudioMetrics.workspaceMinimum
    }
    override func close() { model.cancel(); super.close() }
}

struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 16
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.08)))
            for row in 0...Int(size.height / side) {
                for column in 0...Int(size.width / side) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)),
                                 with: .color(.gray.opacity(0.18)))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct ForegroundSubject: Identifiable {
    let id: Int
    let preview: CGImage
}
extension CaptureImageCleanup {
    static func foregroundErasureMask(_ image: CGImage, instances: IndexSet? = nil) throws -> RepairRasterMask {
        try Task.checkCancellation(); try validate(image)
        guard Double(image.width)*Double(image.height) <= 20_000_000 else { throw CaptureError.message(L10n.text("主体分析最多支持2000万像素。")) }
        let handler = VNImageRequestHandler(cgImage: image,options: [:]), request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request]); try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CaptureError.message(L10n.text("没有识别到明确主体，请保留原图并手动精修。"))
        }
        let chosen = instances ?? observation.allInstances
        guard !chosen.isEmpty, chosen.isSubset(of: observation.allInstances) else {
            throw CaptureError.message(L10n.text("所选主体不在当前图片中，请重新识别。"))
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: chosen,from: handler)
        try Task.checkCancellation()
        return try ForegroundMaskPixels.erasure(buffer,width: image.width,height: image.height)
    }

    static func foregroundSubjects(_ image: CGImage) throws -> [ForegroundSubject] {
        try Task.checkCancellation()
        try validate(image)
        guard Double(image.width)*Double(image.height)<=20_000_000 else { throw CaptureError.message(L10n.text("主体分析最多支持2000万像素。")) }
        let handler=VNImageRequestHandler(cgImage:image,options:[:]),request=VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request]);try Task.checkCancellation()
        guard let observation=request.results?.first,!observation.allInstances.isEmpty else { throw CaptureError.message(L10n.text("没有识别到明确主体，可使用画笔手工修正。")) }
        return try subjectPreviews(handler:handler,observation:observation)
    }
    static func subjectPreviews(handler: VNImageRequestHandler, observation: VNInstanceMaskObservation) throws -> [ForegroundSubject] {
        return try Array(observation.allInstances.prefix(16)).compactMap { id in
            try autoreleasepool { () throws -> ForegroundSubject? in
                try Task.checkCancellation()
                let buffer=try observation.generateMaskedImage(ofInstances:IndexSet(integer:id),from:handler,croppedToInstancesExtent:false)
                let image=CIImage(cvPixelBuffer:buffer),scale=min(1,240/max(image.extent.width,image.extent.height))
                let small=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
                guard let preview=CIContext(options:[.cacheIntermediates:false]).createCGImage(small,from:small.extent) else { return nil }
                return .init(id:id,preview:preview)
            }
        }
    }
}
