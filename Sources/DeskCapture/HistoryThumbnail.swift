import SwiftUI
import ImageIO

struct ThumbnailStatistics { let items: Int; let pixelBytes: Int; let decodes: Int }
actor HistoryThumbnailCache {
    static let shared = HistoryThumbnailCache()
    private struct Entry { let image: CGImage; let bytes: Int; var access: UInt64 }
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private var decodes = 0
    private let byteBudget: Int
    private let itemBudget: Int
    init(byteBudget: Int = 16 * 1024 * 1024, itemBudget: Int = 64) {
        self.byteBudget = max(0, byteBudget); self.itemBudget = max(0, itemBudget)
    }
    func image(at url: URL, edge: Int = 280) throws -> CGImage {
        try Task.checkCancellation()
        guard (16...512).contains(edge) else { throw CaptureError.message(L10n.text("缩略图尺寸超出范围。")) }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 128_000_000 else { throw CaptureError.message(L10n.text("缩略图源文件无效或超过128MB。")) }
        let key = "\(url.standardizedFileURL.path):\(edge):\(size):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        clock &+= 1
        if var entry = entries[key] { entry.access = clock; entries[key] = entry; return entry.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 60000, h <= 60000, Double(w) * Double(h) <= 80_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
                  kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CaptureError.message(L10n.text("无法读取缩略图。")) }
        try Task.checkCancellation(); decodes += 1
        let cost = image.bytesPerRow * image.height
        if cost <= byteBudget && itemBudget > 0 {
            while !entries.isEmpty && (bytes + cost > byteBudget || entries.count >= itemBudget) {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bytes; entries.removeValue(forKey: oldest.key)
            }
            entries[key] = .init(image: image, bytes: cost, access: clock); bytes += cost
        }
        return image
    }
    func statistics() -> ThumbnailStatistics { .init(items: entries.count, pixelBytes: bytes, decodes: decodes) }
    func clear() { entries = [:]; bytes = 0 }
}

struct HistoryThumbnailView: View {
    let url: URL
    @State private var image: CGImage?
    @State private var failure = false
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if failure { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary).help(L10n.text("缩略图不可用；原文件未修改")) }
            else { ProgressView().controlSize(.small) }
        }.task(id: url) {
            image = nil; failure = false
            do {
                let value = try await HistoryThumbnailCache.shared.image(at: url)
                guard !Task.isCancelled else { return }; image = value
            } catch { if !Task.isCancelled { failure = true } }
        }
    }
}
