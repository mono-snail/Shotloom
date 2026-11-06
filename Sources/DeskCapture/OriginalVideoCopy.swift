import Foundation
import Darwin

/// Run off the main thread. Only the final rename can replace the destination.
enum OriginalVideoCopy {
    static func copy(_ input: URL, to output: URL, afterChunk: (() throws -> Void)? = nil) throws {
        try Task.checkCancellation()
        let source = input.resolvingSymlinksInPath().standardizedFileURL
        let destination = output.resolvingSymlinksInPath().standardizedFileURL
        guard source != destination else { throw CaptureError.message(L10n.text("请选择其他保存位置，原片不会被覆盖。")) }
        // URL.resourceValues caches values on the URL. These comparisons must
        // perform fresh filesystem reads, including after a path replacement.
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw CaptureError.message(L10n.text("原片不是可读取的视频文件。")) }
        if let other = try? FileManager.default.attributesOfItem(atPath: destination.path),
           sameIdentity(before, other) {
            throw CaptureError.message(L10n.text("保存位置指向原片，请另选文件名。"))
        }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-copy-\(UUID()).tmp")
        guard FileManager.default.createFile(atPath: stage.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.message(L10n.text("无法在保存位置创建临时文件，请检查可用空间和写入权限。"))
        }
        defer { try? FileManager.default.removeItem(at: stage) }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: stage)
        defer { try? writer.close() }
        var bytes = 0
        while true {
            try Task.checkCancellation()
            let count = try autoreleasepool {
                let data = try reader.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { return 0 }
                try writer.write(contentsOf: data); try afterChunk?()
                return data.count
            }
            if count == 0 { break }
            bytes += count
        }
        try writer.synchronize(); try writer.close(); try reader.close()
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        guard bytes == (before[.size] as? NSNumber)?.intValue,
              (after[.size] as? NSNumber) == (before[.size] as? NSNumber),
              (after[.modificationDate] as? Date) == (before[.modificationDate] as? Date), sameIdentity(before, after) else {
            throw CaptureError.message(L10n.text("复制期间原片发生变化，未替换目的文件。请等待录制保存完成后重试。"))
        }
        try Task.checkCancellation()
        guard rename(stage.path, output.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func sameIdentity(_ a: [FileAttributeKey: Any], _ b: [FileAttributeKey: Any]) -> Bool {
        guard let device = a[.systemNumber] as? NSNumber, let inode = a[.systemFileNumber] as? NSNumber else { return false }
        return device == b[.systemNumber] as? NSNumber && inode == b[.systemFileNumber] as? NSNumber
    }
}
