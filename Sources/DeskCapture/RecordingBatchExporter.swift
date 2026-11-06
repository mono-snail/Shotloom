import Foundation

enum RecordingBatchExporter {
    static func export(_ entries: [RecordingLibraryEntry], root: URL, includeSources: Bool, to output: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let manager = FileManager.default
        guard !entries.isEmpty, entries.count <= 1000, Set(entries.map(\.id)).count == entries.count,
              !manager.fileExists(atPath: output.path) else { throw CaptureError.message(L10n.text("选择1–1000份录屏，并使用新输出目录。")) }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-video-export-\(UUID())")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        var leases: [RecordingSessionLease] = []
        defer { withExtendedLifetime(leases) {} }
        var total: Int64 = 0, files = 0
        func inspect(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw CaptureError.message(L10n.text("录屏导出不接受符号链接或特殊文件。")) }
            if values.isRegularFile == true { files += 1; total += Int64(values.fileSize ?? 0) }
            guard files <= 20_000, total <= 20_000_000_000 else { throw CaptureError.message(L10n.text("批次最多2万个文件、20GB。")) }
            try Task.checkCancellation()
        }
        for (index, entry) in entries.enumerated() {
            guard entry.id.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  !entry.id.lastPathComponent.hasPrefix(".") else { throw CaptureError.message(L10n.text("素材不属于当前录屏库。")) }
            try inspect(entry.id)
            if manager.fileExists(atPath: RecordingSessionJournal.url(entry.id).path) { leases.append(try RecordingSessionLease(directory: entry.id)) }
            if includeSources {
                guard let enumerator = manager.enumerator(at: entry.id, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { throw CaptureError.message(L10n.text("无法枚举录屏素材。")) }
                for case let file as URL in enumerator { try inspect(file) }
                try manager.copyItem(at: entry.id, to: stage.appendingPathComponent(String(format: "recording-%04d", index + 1)))
            } else {
                guard let video = entry.video, (video.deletingLastPathComponent().standardizedFileURL == entry.id.standardizedFileURL || RecordingSessionRecovery.completedVideo(entry.id)?.standardizedFileURL == video.standardizedFileURL) else { throw CaptureError.message(L10n.text("所选录屏尚无成片；可先恢复成片或明确导出全部素材。")) }
                try inspect(video)
                try manager.copyItem(at: video, to: stage.appendingPathComponent(String(format: "recording-%04d", index + 1) + "." + video.pathExtension.lowercased()))
            }
        }
        try beforeCommit?(); try Task.checkCancellation(); try manager.moveItem(at: stage, to: output)
    }
}
