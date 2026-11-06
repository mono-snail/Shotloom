import Foundation
import CoreML
import CoreImage

struct StoredRepairModel: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let importedAt: Date
    let provenance: String
    let imageInput: String
    let maskInput: String
    let imageOutput: String
    let width: Int
    let height: Int
    let bytes: Int64
}

/// Only owns UUID directories below its root. User-selected originals are never moved.
actor RepairModelLibrary {
    static let shared = RepairModelLibrary()
    let root: URL
    private var cached: (UUID, MLModel)?
    private(set) var activeModel: UUID?
    init(root: URL? = nil) {
        let diagnosticRoot = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("models", isDirectory: true) }
        self.root = root ?? diagnosticRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskCapture/Models/Inpainting", isDirectory: true)
    }
    func list() throws -> [StoredRepairModel] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
            let metadata = url.appendingPathComponent("model.json")
            guard let size = try? metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
                  let data = try? Data(contentsOf: metadata), data.count <= 16_384,
                  let model = try? JSONDecoder().decode(StoredRepairModel.self, from: data), model.id.uuidString == url.lastPathComponent,
                  (16...1024).contains(model.width), (16...1024).contains(model.height), model.bytes > 0, model.bytes <= 1_500_000_000 else { return nil }
            return model
        }.sorted { $0.importedAt > $1.importedAt }
    }
    func importModel(from source: URL, provenance: String) throws -> StoredRepairModel {
        guard activeModel == nil else { throw CaptureError.message(L10n.text("模型正在修复，请完成或取消后再管理模型。")) }
        guard ["mlmodel", "mlpackage", "mlmodelc"].contains(source.pathExtension.lowercased()) else {
            throw CaptureError.message(L10n.text("请选择Core ML的.mlmodel、.mlpackage或.mlmodelc文件。"))
        }
        _ = try Self.checkedSize(source)
        try Task.checkCancellation()
        let compiled = source.pathExtension.lowercased() == "mlmodelc" ? source : try MLModel.compileModel(at: source)
        defer { if compiled != source { try? FileManager.default.removeItem(at: compiled) } }
        try Task.checkCancellation()
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        guard inputs.count == 2,
              let mask = inputs.first(where: { $0.key.lowercased().contains("mask") && $0.value.imageConstraint != nil }),
              let image = inputs.first(where: { $0.key != mask.key && $0.value.imageConstraint != nil }),
              let constraint = image.value.imageConstraint,
              let maskConstraint = mask.value.imageConstraint,
              (16...1024).contains(constraint.pixelsWide), (16...1024).contains(constraint.pixelsHigh),
              maskConstraint.pixelsWide == constraint.pixelsWide, maskConstraint.pixelsHigh == constraint.pixelsHigh,
              model.modelDescription.outputDescriptionsByName.count == 1,
              let output = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.imageConstraint != nil }) else {
            throw CaptureError.message(L10n.text("模型需有两个同尺寸图像输入（其中一个名称含mask）和一个图像输出，边长16–1024。此适配器暂不接受MultiArray模型。"))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID(), stage = root.appendingPathComponent(".import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: compiled, to: stage.appendingPathComponent("Model.mlmodelc"))
        let bytes = try Self.checkedSize(stage)
        let item = StoredRepairModel(id: id, name: String(source.deletingPathExtension().lastPathComponent.prefix(120)), importedAt: Date(),
            provenance: String(provenance.prefix(2048)), imageInput: image.key, maskInput: mask.key, imageOutput: output.key,
            width: constraint.pixelsWide, height: constraint.pixelsHigh, bytes: bytes)
        try JSONEncoder().encode(item).write(to: stage.appendingPathComponent("model.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: root.appendingPathComponent(id.uuidString, isDirectory: true))
        return item
    }
    func remove(_ id: UUID) throws {
        guard activeModel == nil else { throw CaptureError.message(L10n.text("模型正在修复，请完成或取消后再管理模型。")) }
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
              try list().contains(where: { $0.id == id }) else { throw CaptureError.message(L10n.text("模型目录不属于本应用，未执行移除。")) }
        if cached?.0 == id { cached = nil }
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
    func infer(image: CGImage, mask: CGImage, using id: UUID) async throws -> CGImage {
        guard activeModel == nil else { throw CaptureError.message(L10n.text("已有模型修复任务，请完成或取消后再开始。")) }
        guard let item = try list().first(where: { $0.id == id }) else { throw CaptureError.message(L10n.text("没有找到所选模型，请导入模型或使用纹理修补。")) }
        try Task.checkCancellation()
        activeModel = id
        defer { activeModel = nil }
        let model: MLModel
        if let existing = cached, existing.0 == id { model = existing.1 }
        else {
            let configuration = MLModelConfiguration(); configuration.computeUnits = .all
            model = try MLModel(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("Model.mlmodelc"), configuration: configuration)
            cached = (id,model)
        }
        guard let imageConstraint = model.modelDescription.inputDescriptionsByName[item.imageInput]?.imageConstraint,
              let maskConstraint = model.modelDescription.inputDescriptionsByName[item.maskInput]?.imageConstraint,
              imageConstraint.pixelsWide == item.width, imageConstraint.pixelsHigh == item.height,
              maskConstraint.pixelsWide == item.width, maskConstraint.pixelsHigh == item.height,
              model.modelDescription.outputDescriptionsByName[item.imageOutput]?.imageConstraint != nil else {
            throw CaptureError.message(L10n.text("模型输入格式已变化，请重新导入。"))
        }
        let rgb = try Self.resized(image, width: item.width, height: item.height, gray: false)
        let gray = try Self.resized(mask, width: item.width, height: item.height, gray: true)
        let provider = try MLDictionaryFeatureProvider(dictionary: [item.imageInput: try MLFeatureValue(cgImage: rgb, constraint: imageConstraint, options: nil),
            item.maskInput: try MLFeatureValue(cgImage: gray, constraint: maskConstraint, options: nil)])
        let result = try await model.prediction(from: provider)
        try Task.checkCancellation()
        guard let pixels = result.featureValue(for: item.imageOutput)?.imageBufferValue else { throw CaptureError.message(L10n.text("修复模型未返回图像。")) }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard ci.extent.width <= 2048, ci.extent.height <= 2048,
              let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(ci, from: ci.extent) else {
            throw CaptureError.message(L10n.text("修复模型输出尺寸超出预算或不可读取。"))
        }
        return output
    }
    private static func resized(_ image: CGImage, width: Int, height: Int, gray: Bool) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("无法分配模型输入。"))
        }
        context.interpolationQuality = gray ? .none : .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw CaptureError.message(L10n.text("模型输入转换失败。")) }; return output
    }
    static func checkedSize(_ url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey,.isRegularFileKey,.isDirectoryKey,.fileSizeKey]
        let rootValues = try url.resourceValues(forKeys: keys)
        guard rootValues.isSymbolicLink != true else { throw CaptureError.message(L10n.text("模型不能包含符号链接。")) }
        if rootValues.isRegularFile == true {
            let size = Int64(rootValues.fileSize ?? 0)
            guard size > 0, size <= 1_500_000_000 else { throw CaptureError.message(L10n.text("模型为空或超过1.5GB。")) }; return size
        }
        guard rootValues.isDirectory == true, let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            throw CaptureError.message(L10n.text("模型目录不可读取。"))
        }
        var bytes: Int64 = 0, count = 0
        for case let entry as URL in iterator {
            try Task.checkCancellation(); count += 1
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, count <= 10_000 else { throw CaptureError.message(L10n.text("模型包含链接或文件数超过10000。")) }
            bytes += Int64(values.fileSize ?? 0)
            guard bytes <= 1_500_000_000 else { throw CaptureError.message(L10n.text("模型超过1.5GB。")) }
        }
        guard bytes > 0 else { throw CaptureError.message(L10n.text("模型目录为空。")) }; return bytes
    }
}
