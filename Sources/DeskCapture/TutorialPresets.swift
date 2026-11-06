import AppKit
import ImageIO

struct TutorialPreset: Codable, Identifiable, Equatable {
    var version = 1
    var id = UUID()
    var name: String
    var backgroundStyle = BeautifyStyle.frost
    var layout = BeautifyLayout.original
    var padding = 0.09
    var roundness = 0.0
    var palette: [String] = []
    var annotation: SavedAnnotationStyle?
    var backgroundPNG: Data?
    func validate() throws {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 40,
              padding.isFinite, (0...0.6).contains(padding), roundness.isFinite, (0...1).contains(roundness),
              palette.count <= 12, palette.allSatisfy({ CaptureColorAnalysis.parse($0) != nil }),
              annotation.map({ $0.valid && $0.name.count <= 40 && ($0.fontName?.count ?? 0) <= 128 &&
                  ($0.iconSize.map { $0.isFinite && (24...180).contains($0) } ?? true) }) ?? true else {
            throw CaptureError.message(L10n.text("预设版本、名称、颜色或样式参数无效。"))
        }
        _ = try background()
    }
    func background() throws -> CGImage? {
        guard let data = backgroundPNG else { return nil }
        guard data.count <= 16_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 8000, h <= 8000, w * h <= 4_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.message(L10n.text("自选背景需为单帧、最多400万像素且编码不超过16MB。")) }
        return image
    }
    static func backgroundData(_ image: CGImage) throws -> Data {
        let scale = min(1, 2000 / Double(max(image.width, image.height)))
        let resized = try CaptureImageTransform.render(image, width: max(1, Int(Double(image.width) * scale)), height: max(1, Int(Double(image.height) * scale)))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CaptureError.message(L10n.text("背景编码失败。")) }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 16_000_000 else { throw CaptureError.message(L10n.text("背景编码失败或超过16MB。")) }
        return data as Data
    }
    func encoded() throws -> Data {
        try validate(); let data = try JSONEncoder().encode(self)
        guard data.count <= 24_000_000 else { throw CaptureError.message(L10n.text("预设超过24MB。")) }; return data
    }
    static func decode(_ data: Data) throws -> TutorialPreset {
        guard data.count <= 24_000_000 else { throw CaptureError.message(L10n.text("预设超过24MB。")) }
        let preset = try JSONDecoder().decode(Self.self, from: data)
        try preset.validate(); return preset
    }
    static func legacy(_ old: BeautifyPreset, background: CGImage?) throws -> TutorialPreset {
        guard old.backgroundFilename == nil || background != nil else { throw CaptureError.message(L10n.text("旧预设的自选背景缺失，未静默丢弃。")) }
        var preset = TutorialPreset(name: old.name)
        preset.backgroundStyle = old.style; preset.layout = old.layout; preset.padding = old.padding; preset.roundness = old.roundness
        if let background { preset.backgroundPNG = try backgroundData(background) }
        try preset.validate(); return preset
    }
    func render(_ source: CGImage) throws -> CGImage {
        try validate()
        return try CaptureBeautifier.render(source, style: backgroundStyle, paddingPercent: padding, roundness: roundness, layout: layout, customBackground: background())
    }
}

actor TutorialPresetLibrary {
    static let shared = TutorialPresetLibrary()
    let directory: URL
    init(directory: URL? = nil) {
        let diagnostic = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("tutorial-presets") }
        self.directory = directory ?? diagnostic ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskCapture/TutorialPresets")
    }
    func list() throws -> [TutorialPreset] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "deskpreset" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        guard files.count <= 60 else { throw CaptureError.message(L10n.text("预设库超过60项，请移除部分预设。")) }
        let totalBytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard totalBytes <= 64_000_000 else { throw CaptureError.message(L10n.text("预设库超过64MB，原文件已保留，请先移出部分预设。")) }
        return try files.map { url in
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 24_000_000 else { throw CaptureError.message(L10n.text("本地预设超过24MB，原文件已保留。")) }
            let preset = try TutorialPreset.decode(Data(contentsOf: url))
            guard preset.id.uuidString == url.deletingPathExtension().lastPathComponent else { throw CaptureError.message(L10n.text("预设标识与文件不一致，原文件已保留。")) }
            return preset
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func save(_ preset: TutorialPreset) throws {
        let data = try preset.encoded()
        let existing = try list()
        guard existing.contains(where: { $0.id == preset.id }) || existing.count < 60 else { throw CaptureError.message(L10n.text("最多60项教程预设。")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existingBytes = try existing.filter { $0.id != preset.id }.reduce(0) { $0 + (try directory.appendingPathComponent("\($1.id).deskpreset").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard existingBytes + data.count <= 64_000_000 else { throw CaptureError.message(L10n.text("保存后预设库将超过64MB。")) }
        try Task.checkCancellation()
        try data.write(to: directory.appendingPathComponent("\(preset.id).deskpreset"), options: .atomic)
    }
    func remove(_ id: UUID) throws {
        try Task.checkCancellation()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).deskpreset"))
    }
    func legacyPresets(in oldDirectory: URL) throws -> [BeautifyPreset] {
        let index = oldDirectory.appendingPathComponent("presets.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        guard (try index.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 128_000 else { throw CaptureError.message(L10n.text("旧预设索引超过128KB。")) }
        let values = try JSONDecoder().decode([BeautifyPreset].self, from: Data(contentsOf: index))
        guard values.count <= 30 else { throw CaptureError.message(L10n.text("旧预设超过30项。")) }; return values
    }
    func importLegacy(_ old: BeautifyPreset, from oldDirectory: URL) throws -> TutorialPreset {
        var background: CGImage?
        if let filename = old.backgroundFilename {
            guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.hasPrefix("."), filename.hasSuffix(".png") else { throw CaptureError.message(L10n.text("旧背景路径无效。")) }
            background = try CaptureImageRead.load(oldDirectory.appendingPathComponent(filename))
        }
        let preset = try TutorialPreset.legacy(old, background: background)
        try save(preset); return preset
    }
    func importFile(_ url: URL) throws -> TutorialPreset {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 24_000_000 else { throw CaptureError.message(L10n.text("预设超过24MB。")) }
        var preset = try TutorialPreset.decode(Data(contentsOf: url))
        preset.id = UUID() // Imported files never replace a local preset implicitly.
        try save(preset); return preset
    }
    static func export(_ preset: TutorialPreset, to url: URL) throws {
        let data = try preset.encoded(); try Task.checkCancellation(); try data.write(to: url, options: .atomic)
    }
}
