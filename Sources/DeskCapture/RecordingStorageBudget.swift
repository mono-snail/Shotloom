import Foundation

enum RecordingStorageBudget {
    static func require(_ directory: URL, bytes: Int64, available: Int64? = nil) throws {
        guard bytes >= 0 else { throw CaptureError.message(L10n.text("磁盘预算无效。")) }
        let free = try available ?? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        guard let free else { throw CaptureError.message(L10n.text("无法确认可用磁盘空间，未继续写入。")) }
        guard free >= bytes else { throw CaptureError.message(L10n.text("可用磁盘空间不足；本次需要预留至少\(bytes / 1_000_000)MB，已录制原片仍保留。")) }
    }
}
