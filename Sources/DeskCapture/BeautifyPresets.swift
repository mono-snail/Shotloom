import AppKit
import Combine

struct BeautifyPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var style: BeautifyStyle
    var layout: BeautifyLayout
    var padding: Double
    var roundness: Double
    var backgroundFilename: String?
}

@MainActor final class BeautifyPresetStore: ObservableObject {
    @Published private(set) var presets: [BeautifyPreset] = []
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskCapture/BeautifyPresets", isDirectory: true)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("presets.json")),
           let saved = try? JSONDecoder().decode([BeautifyPreset].self, from: data) { presets = saved }
    }
    func save(name: String, style: BeautifyStyle, layout: BeautifyLayout, padding: Double, roundness: Double, background: CGImage?) async throws {
        guard presets.count < 30 else { throw CaptureError.message(L10n.text("最多保存 30 个预设，请先移除不再使用的预设。")) }
        let id = UUID(), filename = background == nil ? nil : "\(UUID().uuidString).png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let background, let filename {
            let output = directory.appendingPathComponent(filename)
            try await Task.detached(priority: .userInitiated) { try CaptureImageExport.png(background, to: output) }.value
        }
        let preset = BeautifyPreset(id: id, name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)).isEmpty ? style.title : String(name.prefix(40)),
                                    style: style, layout: layout, padding: padding, roundness: roundness, backgroundFilename: filename)
        let updated = [preset] + presets
        do { try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("presets.json"), options: .atomic); presets = updated }
        catch { if let filename { try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename)) }; throw error }
    }
    func background(for preset: BeautifyPreset) -> CGImage? {
        guard let name = preset.backgroundFilename, name == URL(fileURLWithPath: name).lastPathComponent,
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    func loadBackground(for preset: BeautifyPreset) async throws -> CGImage? {
        let folder = directory
        let worker = Task.detached(priority: .userInitiated) { () throws -> CGImage? in
            try Task.checkCancellation()
            guard let name = preset.backgroundFilename else { return nil }
            guard name == URL(fileURLWithPath: name).lastPathComponent else { throw CaptureError.message(L10n.text("预设背景路径无效。")) }
            let file = folder.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 64_000_000,
                  let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 80_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2500] as CFDictionary) else {
                throw CaptureError.message(L10n.text("预设背景无法读取或超过大小限制。"))
            }
            try Task.checkCancellation(); return image
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    func remove(_ preset: BeautifyPreset) throws {
        let updated = presets.filter { $0.id != preset.id }
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("presets.json"), options: .atomic)
        presets = updated
        if let name = preset.backgroundFilename, name == URL(fileURLWithPath: name).lastPathComponent {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
