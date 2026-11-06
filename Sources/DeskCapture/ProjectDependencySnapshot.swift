import Foundation
import Darwin

/// Detects replacement and ordinary in-place edits throughout a multi-output export.
/// This is a local consistency guard, not a cryptographic proof against a hostile writer.
struct ProjectDependencySnapshot: Equatable, Sendable {
    struct Stamp: Equatable, Sendable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64
    }
    private let files: [URL: Stamp]
    private let absent: Set<URL>
    init(_ urls: [URL]) throws {
        var files: [URL: Stamp] = [:], absent: Set<URL> = []
        for url in Set(urls) {
            try Task.checkCancellation()
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                if errno == ENOENT { absent.insert(url); continue }
                throw CaptureError.message(L10n.text("无法读取项目依赖状态。"))
            }
            guard value.st_mode & S_IFMT == S_IFREG else { throw CaptureError.message(L10n.text("项目依赖必须是普通文件，不能是符号链接。")) }
            files[url] = Stamp(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: value.st_size,
                               modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanos: Int64(value.st_mtimespec.tv_nsec),
                               changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanos: Int64(value.st_ctimespec.tv_nsec))
        }
        self.files = files; self.absent = absent
    }
    func verify() throws {
        guard try Self(Array(files.keys) + Array(absent)) == self else { throw CaptureError.message(L10n.text("导出期间原片或依赖素材已改变，未提交交付结果。")) }
    }
    static func video(_ video: URL, snapshot: RecordingEditSnapshot) throws -> Self {
        var urls = [video, RecordingEditStore.url(for: video), RecordingInteractions.url(for: video), RecordingDrawingTimeline.url(for: video), RecordingCamera.url(for: video)]
        if let metadata = RecordingInteractions.load(video), metadata.editableCursorSource != nil {
            let raw = try EditableCursorSource.resolve(video, metadata: metadata)
            urls += [raw, RecordingInteractions.url(for: raw), RecordingDrawingTimeline.url(for: raw)]
        }
        if let music = snapshot.studio.effects?.edit?.musicPath { urls.append(URL(fileURLWithPath: music)) }
        return try Self(urls)
    }
}
