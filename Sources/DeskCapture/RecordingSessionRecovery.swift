import Foundation
import AVFoundation

struct RecordingRecoveredRange: Sendable {
    let sourceStart: Double
    let duration: Double
    let outputStart: Double
}
enum RecordingSessionRecovery {
    struct Report: Codable { var version = 1; let entry: String; let skippedSegments: Int; let missingCameraSeconds: Double; let recoveredDuration: Double; let checkpointSequence: Int }
    static func map(_ events: [RecordedInteraction], ranges: [RecordingRecoveredRange]) -> [RecordedInteraction] {
        events.compactMap { event in
            guard let range = ranges.first(where: { event.time >= $0.sourceStart && event.time < $0.sourceStart + $0.duration }) else { return nil }
            var event = event; event.time = range.outputStart + event.time - range.sourceStart; return event
        }.sorted { $0.time < $1.time }
    }
    static func map(_ drawing: RecordingDrawingTimeline, ranges: [RecordingRecoveredRange]) -> RecordingDrawingTimeline {
        var result: [RecordingDrawingFrame] = [], lastIndex: Int?
        for range in ranges {
            if let index = drawing.index(at: range.sourceStart), index != lastIndex {
                var frame = drawing.frames[index]; frame.time = range.outputStart; result.append(frame); lastIndex = index
            }
            for (index, item) in drawing.frames.enumerated() where item.time >= range.sourceStart && item.time < range.sourceStart + range.duration && index != lastIndex {
                var frame = item; frame.time = range.outputStart + frame.time - range.sourceStart; result.append(frame); lastIndex = index
            }
        }
        return .init(frames: result)
    }
    static func completedVideo(_ directory: URL) -> URL? {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { return nil }
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where folder.lastPathComponent.hasPrefix("DeskCapture-Recovered-") {
            guard UUID(uuidString: String(folder.lastPathComponent.dropFirst("DeskCapture-Recovered-".count))) != nil,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true else { continue }
            let report = folder.appendingPathComponent("recovery-output.json")
            guard ((try? report.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 100_000,
                  let bytes = try? Data(contentsOf: report), let value = try? JSONDecoder().decode(Report.self, from: bytes), value.version == 1,
                  PortableProject.safe(value.entry) else { continue }
            let video = folder.appendingPathComponent(value.entry)
            if (try? video.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true { return video }
        }
        return nil
    }
    static func recover(_ directory: URL) async throws -> (URL, Int) {
        let lease = try await Task.detached(priority: .utility) { try RecordingSessionLease(directory: directory) }.value
        defer { withExtendedLifetime(lease) {} }
        let loaded = try await Task.detached(priority: .utility) { () throws -> (RecordingSessionManifest, RecordingInteractions, RecordingDrawingTimeline) in
            guard let manifest = try RecordingSessionJournal.read(directory) else { throw CaptureError.message(L10n.text("缺少录制恢复清单。")) }
            let timeline = try RecordingSessionJournal.readTimeline(directory, manifest: manifest)
            return (manifest, timeline.0, timeline.1)
        }.value
        var usable: [URL] = [], ranges: [RecordingRecoveredRange] = [], cameras: [CameraRecordingSegment] = [], offset = 0.0, missingCamera = 0.0
        for segment in loaded.0.segments {
            try Task.checkCancellation()
            let video = directory.appendingPathComponent(segment.video), asset = AVURLAsset(url: video)
            guard (try? video.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true,
                  let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
                  (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false else { continue }
            usable.append(video); ranges.append(.init(sourceStart: segment.sourceStart, duration: duration, outputStart: offset)); offset += duration
            if let file = segment.camera {
                let camera = directory.appendingPathComponent(file), cameraAsset = AVURLAsset(url: camera)
                let regular = (try? camera.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true
                let cameraDuration = regular ? ((try? await cameraAsset.load(.duration).seconds) ?? 0) : 0
                let available = min(duration, max(0, cameraDuration - segment.cameraOffset))
                if available > 0, (try? await cameraAsset.loadTracks(withMediaType: .video).isEmpty) == false { cameras.append(.init(url: camera, offset: segment.cameraOffset, duration: available)) }
                else { cameras.append(.init(url: nil, offset: 0, duration: available)) }
                if duration > available { cameras.append(.init(url: nil, offset: 0, duration: duration - available)); missingCamera += duration - available }
            } else { cameras.append(.init(url: nil, offset: 0, duration: duration)) }
        }
        guard !usable.isEmpty else { throw CaptureError.message(L10n.text("没有可读取的录制分片；原文件保留。")) }
        let stage = directory.appendingPathComponent(".recovery-\(UUID())"), destination = directory.appendingPathComponent("DeskCapture-Recovered-\(UUID())")
        do {
            let inputs = usable + cameras.compactMap(\.url)
            try await Task.detached(priority: .utility) {
                let bytes = try inputs.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                try RecordingStorageBudget.require(directory, bytes: bytes * 3 + 256_000_000)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            }.value
            let raw = stage.appendingPathComponent("DeskCapture-恢复原片.mp4")
            try await ScreenRecorder.join(usable, to: raw)
            if cameras.contains(where: { $0.url != nil }) { try await CameraRecordingSegment.join(cameras, to: RecordingCamera.url(for: raw), microphoneSources: usable, audioSources: loaded.0.audioSources) }
            var metadata = loaded.1; metadata.events = map(metadata.events, ranges: ranges)
            let drawing = map(loaded.2, ranges: ranges), snapshotMetadata = metadata
            try await Task.detached(priority: .utility) {
                try JSONEncoder().encode(snapshotMetadata).write(to: RecordingInteractions.url(for: raw), options: .atomic)
                try JSONEncoder().encode(drawing).write(to: RecordingDrawingTimeline.url(for: raw), options: .atomic)
            }.value
            var entry = raw
            if metadata.smoothCursor || drawing.frames.contains(where: { !$0.marks.isEmpty }) {
                let processed = stage.appendingPathComponent("DeskCapture-恢复.mp4")
                var options = RecordingEffectsOptions(); options.smartZoom = false; options.background = false; options.shortcuts = false; options.clicks = false; options.camera.enabled = false
                try await RecordingEffectsExporter.export(raw, to: processed, options: options)
                metadata.editableCursorSource = metadata.smoothCursor ? raw.lastPathComponent : nil; metadata.smoothCursor = false
                let processedMetadata = metadata
                try await Task.detached(priority: .utility) {
                    try JSONEncoder().encode(processedMetadata).write(to: RecordingInteractions.url(for: processed), options: .atomic)
                    let camera = RecordingCamera.url(for: raw)
                    if FileManager.default.fileExists(atPath: camera.path) { try FileManager.default.copyItem(at: camera, to: RecordingCamera.url(for: processed)) }
                }.value
                entry = processed
            }
            let skipped = loaded.0.segments.count - usable.count
            let report = Report(entry: entry.lastPathComponent, skippedSegments: skipped, missingCameraSeconds: missingCamera, recoveredDuration: offset, checkpointSequence: loaded.0.sequence)
            let worker = Task.detached(priority: .utility) {
                try JSONEncoder().encode(report).write(to: stage.appendingPathComponent("recovery-output.json"), options: .atomic)
                try Task.checkCancellation(); try FileManager.default.moveItem(at: stage, to: destination)
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            return (destination.appendingPathComponent(entry.lastPathComponent), skipped)
        } catch {
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stage) }.value; throw error
        }
    }
}
