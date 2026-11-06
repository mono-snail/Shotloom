import AppKit
import AVFoundation
import SwiftUI

struct RecordingLibraryEntry: Identifiable {
    let id: URL
    let video: URL?
    let segments: [URL]
    let date: Date
    let bytes: Int64
    var recoveryAvailable = false
}

enum RecordingLibrary {
    static var directory: URL {
        if let diagnostic = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] { return URL(fileURLWithPath: diagnostic).appendingPathComponent("recording-library") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskCapture/Recordings", isDirectory: true) }
    static func entries(directory: URL = Self.directory) -> [RecordingLibraryEntry] { (try? checkedEntries(directory: directory)) ?? [] }
    static func checkedEntries(directory: URL = Self.directory) throws -> [RecordingLibraryEntry] {
        try RecordingBatchTransactions.snapshot(directory) { try enumerateEntries(directory: directory) }
    }
    private static func enumerateEntries(directory: URL) throws -> [RecordingLibraryEntry] {
        let manager = FileManager.default
        let folders = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: .skipsHiddenFiles)
        return try folders.compactMap { folder in
            try Task.checkCancellation()
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return nil }
            let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)
            let finals = files.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.hasPrefix("DeskCapture-") && !$0.lastPathComponent.contains(".camera.") }
            let video = RecordingSessionRecovery.completedVideo(folder) ?? finals.sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }.first
            let segments = files.filter { ["mp4", "mov"].contains($0.pathExtension) && ($0.lastPathComponent.hasPrefix("segment-") || $0.lastPathComponent.hasPrefix("device-")) }.sorted {
                Int($0.deletingPathExtension().lastPathComponent.dropFirst(8)) ?? 0 < Int($1.deletingPathExtension().lastPathComponent.dropFirst(8)) ?? 0
            }
            let journal = try? RecordingSessionJournal.read(folder)
            let recoverable = journal != nil && journal?.status != .completed && RecordingSessionLease.available(folder)
            guard video != nil || !segments.isEmpty else { return nil }
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return RecordingLibraryEntry(id: folder, video: video, segments: segments,
                date: (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, bytes: bytes, recoveryAvailable: recoverable)
        }.sorted { $0.date > $1.date }
    }
    static func recover(_ entry: RecordingLibraryEntry) async throws -> (URL, Int) {
        if FileManager.default.fileExists(atPath: RecordingSessionJournal.url(entry.id).path) { return try await RecordingSessionRecovery.recover(entry.id) }
        var usable: [URL] = []
        for url in entry.segments {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration), duration.isNumeric, duration > .zero,
               (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false { usable.append(url) }
        }
        guard !usable.isEmpty else { throw CaptureError.message(L10n.text("没有已完成写入的视频分段。原始文件仍保留，可在 Finder 检查。")) }
        let output = entry.id.appendingPathComponent("DeskCapture-恢复-\(UUID()).mp4")
        try await ScreenRecorder.join(usable, to: output)
        return (output, entry.segments.count - usable.count)
    }
}

