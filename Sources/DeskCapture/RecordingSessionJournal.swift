import Foundation
import Darwin

final class RecordingSessionLease: @unchecked Sendable {
    private let fd: Int32
    init(directory: URL) throws {
        fd = open(directory.appendingPathComponent(".recording.active.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.message(L10n.text("无法建立录制会话锁。")) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CaptureError.message(L10n.text("录制会话仍在使用。")) }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
    static func available(_ directory: URL) -> Bool {
        guard let lease = try? Self(directory: directory) else { return false }
        withExtendedLifetime(lease) {}; return true
    }
}
struct RecordingSessionSegment: Codable, Sendable {
    var video: String
    var sourceStart: Double
    var duration: Double?
    var camera: String?
    var cameraOffset = 0.0
    var sealed = false
}
struct RecordingSessionManifest: Codable, Sendable {
    enum Status: String, Codable, Sendable { case preparing, recording, paused, finishing, completed, interrupted }
    var version = 1
    var id = UUID()
    var status = Status.preparing
    var sequence = 0
    var checkpointBytes: UInt64 = 0
    var eventCount = 0
    var drawingCount = 0
    var fps: Int
    var smoothCursor: Bool
    var audioSources: [String]?
    var segments: [RecordingSessionSegment] = []
    var finalFile: String?
    var updated = Date()
    func validate() throws {
        guard audioSources.map({ $0.count <= 2 && Set($0).count == $0.count && $0.allSatisfy { ["system", "microphone"].contains($0) } }) ?? true,
              version == 1, (15...60).contains(fps), sequence >= 0, checkpointBytes <= 64_000_000,
              (0...1_000_000).contains(eventCount), (0...2000).contains(drawingCount), segments.count <= 1000,
              Set(segments.map(\.video)).count == segments.count, finalFile.map(PortableProject.safe) ?? true,
              segments.allSatisfy({ PortableProject.safe($0.video) && ["mov", "mp4"].contains(($0.video as NSString).pathExtension) &&
                  $0.sourceStart.isFinite && $0.sourceStart >= 0 && $0.cameraOffset.isFinite && (0...30).contains($0.cameraOffset) &&
                  $0.duration.map({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) != false && ($0.camera.map(PortableProject.safe) ?? true) }) else { throw CaptureError.message(L10n.text("录制恢复清单参数无效。")) }
        for index in segments.indices.dropFirst() where segments[index].sourceStart < segments[index - 1].sourceStart { throw CaptureError.message(L10n.text("录制分段顺序无效。")) }
    }
}
private struct RecordingCheckpointBatch: Codable {
    let sequence: Int
    let events: [RecordedInteraction]
    let drawing: [RecordingDrawingFrame]
}
actor RecordingSessionJournal {
    nonisolated let lease: RecordingSessionLease
    let directory: URL
    private var manifest: RecordingSessionManifest
    static func url(_ directory: URL) -> URL { directory.appendingPathComponent("recording-session.json") }
    static func read(_ directory: URL) throws -> RecordingSessionManifest? {
        let file = url(directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 1_000_000 else { throw CaptureError.message(L10n.text("恢复清单类型或大小无效。")) }
        let manifest = try JSONDecoder().decode(RecordingSessionManifest.self, from: Data(contentsOf: file)); try manifest.validate(); return manifest
    }
    static func create(directory: URL, fps: Int, smoothCursor: Bool, audioSources: [String]? = nil) async throws -> RecordingSessionJournal {
        try await Task.detached(priority: .utility) {
            let lease = try RecordingSessionLease(directory: directory), manifest = RecordingSessionManifest(fps: fps, smoothCursor: smoothCursor, audioSources: audioSources)
            try manifest.validate(); try JSONEncoder().encode(manifest).write(to: url(directory), options: .atomic)
            return RecordingSessionJournal(directory: directory, manifest: manifest, lease: lease)
        }.value
    }
    private init(directory: URL, manifest: RecordingSessionManifest, lease: RecordingSessionLease) { self.directory = directory; self.manifest = manifest; self.lease = lease }
    func checkpoint(segments: [RecordingSessionSegment], status: RecordingSessionManifest.Status, events: [RecordedInteraction], drawing: [RecordingDrawingFrame], finalFile: String? = nil) throws {
        var next = manifest; next.sequence += 1; next.segments = segments; next.status = status; next.finalFile = finalFile; next.updated = Date()
        next.eventCount += events.count; next.drawingCount += drawing.count; try next.validate()
        let bytes = try JSONEncoder().encode(RecordingCheckpointBatch(sequence: next.sequence, events: events, drawing: drawing)) + Data([10])
        guard bytes.count <= 8_000_000, manifest.checkpointBytes + UInt64(bytes.count) <= 64_000_000 else { throw CaptureError.message(L10n.text("恢复检查点超过预算，请结束录制保存。")) }
        let file = directory.appendingPathComponent("recording-checkpoints.jsonl")
        let fd = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.message(L10n.text("无法打开录制检查点。")) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        do {
            try handle.truncate(atOffset: manifest.checkpointBytes); try handle.seek(toOffset: manifest.checkpointBytes)
            try handle.write(contentsOf: bytes); try handle.synchronize(); try Task.checkCancellation()
            next.checkpointBytes += UInt64(bytes.count); try JSONEncoder().encode(next).write(to: Self.url(directory), options: .atomic)
            manifest = next
        } catch { try? handle.truncate(atOffset: manifest.checkpointBytes); throw error }
    }
    static func readTimeline(_ directory: URL, manifest: RecordingSessionManifest) throws -> (RecordingInteractions, RecordingDrawingTimeline) {
        try manifest.validate()
        guard manifest.checkpointBytes > 0 else { return (.init(smoothCursor: manifest.smoothCursor, events: [], recordedFPS: manifest.fps, audioSources: manifest.audioSources), .init()) }
        let file = directory.appendingPathComponent("recording-checkpoints.jsonl")
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, UInt64(values.fileSize ?? 0) >= manifest.checkpointBytes else { throw CaptureError.message(L10n.text("恢复检查点缺失或被截断。")) }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var remaining = manifest.checkpointBytes, pending = Data(), events: [RecordedInteraction] = [], frames: [RecordingDrawingFrame] = [], sequence = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: Int(min(remaining, 1_048_576))) ?? Data()
            guard !bytes.isEmpty else { throw CaptureError.message(L10n.text("恢复检查点未读完整。")) }; remaining -= UInt64(bytes.count); pending.append(bytes)
            while let end = pending.firstIndex(of: 10) {
                let batch = try JSONDecoder().decode(RecordingCheckpointBatch.self, from: pending[..<end])
                guard batch.sequence == sequence + 1, batch.events.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }), batch.drawing.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.marks.count <= 200 }) else { throw CaptureError.message(L10n.text("恢复时间轴顺序或数据无效。")) }
                events += batch.events; frames += batch.drawing; sequence = batch.sequence; pending.removeSubrange(...end)
                guard events.count <= 1_000_000, frames.count <= 2000 else { throw CaptureError.message(L10n.text("恢复时间轴超过预算。")) }
            }
            guard pending.count <= 8_000_000 else { throw CaptureError.message(L10n.text("恢复记录超过预算。")) }
        }
        guard pending.isEmpty, sequence == manifest.sequence, events.count == manifest.eventCount, frames.count == manifest.drawingCount else { throw CaptureError.message(L10n.text("恢复检查点计数不符，未改写原片。")) }
        return (.init(smoothCursor: manifest.smoothCursor, events: events, recordedFPS: manifest.fps, audioSources: manifest.audioSources), .init(frames: frames))
    }
}
