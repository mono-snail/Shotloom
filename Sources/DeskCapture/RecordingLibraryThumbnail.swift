import AVFoundation
import SwiftUI

/// Small, bounded previews; full movies and decoders are never retained by rows.
actor RecordingThumbnailCache {
    static let shared = RecordingThumbnailCache()
    private struct Entry { let image: CGImage; let bytes: Int; var access: UInt64 }
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private let byteBudget = 8 * 1024 * 1024
    private let itemBudget = 48

    func image(at url: URL) async throws -> CGImage {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CaptureError.message(L10n.text("视频预览源无效。")) }
        let key = "\(url.standardizedFileURL.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        clock &+= 1
        if var entry = entries[key] { entry.access = clock; entries[key] = entry; return entry.image }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 140)
        let result = try await withTaskCancellationHandler {
            try await generator.image(at: .zero).image
        } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        if var existing = entries[key] {
            clock &+= 1; existing.access = clock; entries[key] = existing; return existing.image
        }
        let cost = result.bytesPerRow * result.height
        if cost <= byteBudget {
            while !entries.isEmpty && (bytes + cost > byteBudget || entries.count >= itemBudget) {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.bytes; entries.removeValue(forKey: oldest.key)
            }
            clock &+= 1
            entries[key] = Entry(image: result, bytes: cost, access: clock); bytes += cost
        }
        return result
    }
}

struct RecordingLibraryThumbnail: View {
    let url: URL?
    let revision: UUID
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var displayedURL: URL?
    private struct Key: Hashable { let url: URL?; let revision: UUID }
    var body: some View {
        ZStack {
            Palette.canvas
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(3)
            } else {
                Image(systemName: url == nil ? "arrow.counterclockwise.circle" : "film")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(Palette.ice)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel(url == nil ? L10n.text("可恢复录制分段") : L10n.text("视频预览"))
        .help(failure ?? (url == nil ? L10n.text("原始分段仍可恢复") : L10n.text("打开视频编辑")))
        .task(id: Key(url: url, revision: revision)) {
            if displayedURL != url { image = nil; displayedURL = url }
            failure = nil
            guard let url else { return }
            do {
                let result = try await RecordingThumbnailCache.shared.image(at: url)
                guard !Task.isCancelled else { return }; image = result
            } catch {
                guard !Task.isCancelled else { return }; image = nil; failure = error.localizedDescription
            }
        }
    }
}
