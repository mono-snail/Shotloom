import Foundation
import AVFoundation

/// Availability of the separate camera asset, not proof of every frame's quality.
enum RecordingCameraMaterial: Equatable, Sendable {
    case checking, missing, ready, unreadable

    func blocksComposition(enabled: Bool, requested: Bool) -> Bool {
        enabled && (self == .checking || self == .unreadable || (requested && self == .missing))
    }

    static func inspect(for source: URL) async throws -> Self {
        try Task.checkCancellation()
        let url = RecordingCamera.url(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return .unreadable }
            let asset = AVURLAsset(url: url)
            defer { withExtendedLifetime(asset) {} }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            return !tracks.isEmpty && duration.isNumeric && duration.seconds > 0 ? .ready : .unreadable
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return .unreadable }
    }

    var detail: String {
        switch self {
        case .checking: L10n.text("正在检查摄像头素材…")
        case .missing: L10n.text("此视频没有配套的摄像头素材。若录制时已开启摄像头，请保留原始分段并检查录制警告。")
        case .ready: L10n.text("摄像头已保存，开启画中画后会显示在成片预览中，可直接拖动调整位置。另存原片只包含屏幕。")
        case .unreadable: L10n.text("摄像头文件存在，但无法读取有效视频。屏幕原片仍保留，请保留录制分段；本次不能确认画中画已保存成功。")
        }
    }
}
