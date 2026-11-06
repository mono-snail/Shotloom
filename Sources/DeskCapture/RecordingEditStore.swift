import Foundation
import CryptoKit
import Darwin

struct RecordingEditSnapshot: Codable {
    var version = 1
    var revision = UUID()
    var captions: [CaptionSegment]
    var studio: RecordingStudioProject
    func validate() throws {
        guard (studio.trimStart == nil && studio.trimEnd == nil) || (studio.trimStart.map { $0.isFinite && $0 >= 0 } == true && studio.trimEnd.map { $0.isFinite && $0 > (studio.trimStart ?? 0) && $0 <= 1_000_000 } == true) else { throw CaptureError.message(L10n.text("工程裁剪范围无效。")) }
        guard version == 1, captions.count <= 20_000, Set(captions.map(\.id)).count == captions.count,
              captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= 1_000_000 && $0.text.utf8.count <= 64_000 }),
              studio.version == 1, studio.lenses.count <= 2000, studio.lenses.allSatisfy(\.valid),
              (studio.effects?.edit?.sections.count ?? 0) <= 2000,
              studio.effects?.edit?.sections.allSatisfy(\.valid) != false else { throw CaptureError.message(L10n.text("字幕或剪辑工程参数无效。")) }
        try studio.effects?.optics?.validate(); try studio.effects?.reframing?.validate()
        try studio.effects?.audio.validate()
        try studio.effects?.quality?.validate()
        if let cues = studio.effects?.privacy { _ = try VideoPrivacyTimeline(cues, duration: 1_000_000) }
        try studio.effects?.cursor?.validate(duration: 1_000_000)
        try studio.effects?.cameraAutomation?.validate(duration: 3600)
        if let cues = studio.effects?.cameraLayouts { _ = try CameraLayoutTimeline(cues, duration: 1_000_000) }
    }
}

enum RecordingEditStore {
    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("editing.json") }
    static func exists(_ video: URL) -> Bool { FileManager.default.fileExists(atPath: url(for: video).path) }
    static func sidecarData(_ file: URL, maximumBytes: Int = 16_000_000) throws -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CaptureError.message(L10n.text("无法读取工程文件，原文件保留。"))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard maximumBytes > 0, maximumBytes < Int.max,
              fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw CaptureError.message(L10n.text("工程文件超过容量限制或不是普通文件。"))
        }
        // Bound the read itself as well as the initial stat: a concurrent writer
        // must not make a legacy sidecar allocate unbounded memory.
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard bytes.count <= maximumBytes else { throw CaptureError.message(L10n.text("工程读取期间超过容量限制。")) }
        return bytes
    }
    static func load(_ video: URL) throws -> RecordingEditSnapshot? {
        guard let contents = try sidecarData(url(for: video)) else { return nil }
        let value = try JSONDecoder().decode(RecordingEditSnapshot.self, from: contents)
        try value.validate(); return value
    }
    static func fingerprint(_ video: URL) throws -> String {
        var hash = SHA256()
        for file in [url(for: video), VideoTranscript.url(for: video), RecordingStudioProject.url(for: video)] {
            if let value = try sidecarData(file) { hash.update(data: Data([1])); hash.update(data: value) }
            else { hash.update(data: Data([0])) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// One canonical file commits captions and studio together. Legacy sidecars
    /// remain untouched for rollback; new readers prefer the canonical snapshot.
    static func save(_ snapshot: RecordingEditSnapshot, for video: URL, expected: String?, beforeCommit: (() throws -> Void)? = nil) throws -> String {
        let lockURL = video.deletingPathExtension().appendingPathExtension("editing.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.message(L10n.text("无法打开字幕工程写入锁。")) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CaptureError.message(L10n.text("另一进程正在保存此工程。")) }
        defer { flock(fd, LOCK_UN) }
        let current = try fingerprint(video)
        guard expected == nil || expected == current else { throw CaptureError.message(L10n.text("磁盘字幕或设置已改变，请重新打开后合并，未覆盖现有文件。")) }
        try snapshot.validate()
        var snapshot = snapshot; snapshot.revision = UUID()
        let bytes = try JSONEncoder().encode(snapshot)
        guard bytes.count <= 16_000_000 else { throw CaptureError.message(L10n.text("字幕工程超过16MB，未保存。")) }
        let target = url(for: video), stage = target.deletingLastPathComponent().appendingPathComponent(".DeskCapture-editing-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: stage) }
        try bytes.write(to: stage, options: .withoutOverwriting)
        try beforeCommit?(); try Task.checkCancellation()
        guard try fingerprint(video) == current else { throw CaptureError.message(L10n.text("保存期间磁盘工程已改变，未覆盖。")) }
        // Atomic replacement is the commit boundary. Return success after it;
        // cancellation before this boundary leaves the previous snapshot intact.
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: target) }
        return (try? fingerprint(video)) ?? ""
    }
}

enum TranscriptEditing {
    static func replacing(_ captions: [CaptionSegment], query: String, replacement: String) throws -> [CaptionSegment] {
        guard !query.isEmpty, query.utf8.count <= 4096, replacement.utf8.count <= 64_000 else { throw CaptureError.message(L10n.text("字幕替换参数超过预算。")) }
        var rows = captions, total = 0
        for i in rows.indices {
            try Task.checkCancellation()
            let source = rows[i].text
            var start = source.startIndex, rebuilt = "", bytes = 0
            func append(_ text: Substring) throws {
                let size = text.utf8.count
                guard bytes + size <= 64_000 else { throw CaptureError.message(L10n.text("替换后的单句超过64KB，未修改。")) }
                rebuilt.append(contentsOf: text); bytes += size
            }
            while let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<source.endIndex) {
                try Task.checkCancellation()
                guard range.upperBound > start else { throw CaptureError.message(L10n.text("字幕替换没有推进，未修改。")) }
                try append(source[start..<range.lowerBound]); try append(Substring(replacement)); start = range.upperBound
            }
            try append(source[start...]); total += bytes + 96
            guard total <= 16_000_000 else { throw CaptureError.message(L10n.text("替换后的字幕超过16MB，未修改。")) }
            rows[i].text = rebuilt
        }
        return rows
    }
    static func sentenceSections(_ captions: [CaptionSegment], duration: Double, speed: Double) throws -> [VideoSection] {
        guard (0.25...4).contains(speed), speed.isFinite, captions.filter(\.keep).count <= 2000 else { throw CaptureError.message(L10n.text("逐句剪辑最多2000句，速度需0.25–4倍。")) }
        let result = captions.filter(\.keep).map { VideoSection(start: $0.start, end: $0.end, speed: speed, captionID: $0.id) }
        guard !result.isEmpty, result.allSatisfy({ $0.valid && $0.end <= duration + 0.001 }) else { throw CaptureError.message(L10n.text("没有有效保留句子，或字幕超出原片范围。")) }
        return result
    }
    static func matching(_ captions: [CaptionSegment], query: String) throws -> [UUID] {
        guard query.utf8.count <= 4096 else { throw CaptureError.message(L10n.text("字幕查询过长。")) }
        return try captions.compactMap { row in
            try Task.checkCancellation()
            return query.isEmpty || row.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil ? row.id : nil
        }
    }
}
