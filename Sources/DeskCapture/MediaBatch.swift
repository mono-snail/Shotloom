import Foundation

struct MediaBatchClassification {
    var addTags: [String] = []
    var removeTags: [String] = []
    var addCollection: UUID?
    var favorite: Bool?
}
enum CaptureBatchExporter {
    static func export(_ records: [CaptureRecord], directory: URL, includeProjects: Bool, to destination: URL,
                       beforeCommit: (() throws -> Void)? = nil) throws {
        let manager = FileManager.default
        guard !records.isEmpty, records.count <= 1000, Set(records.map(\.id)).count == records.count,
              !manager.fileExists(atPath: destination.path) else { throw CaptureError.message(L10n.text("选择1–1000条素材，并使用不存在的新输出目录。")) }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".DeskCapture-batch-export-\(UUID())")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        var total: Int64 = 0
        for (index, record) in records.enumerated() {
            guard (record.filename as NSString).pathExtension.lowercased() == "png",
                  record.projectFilename.map({ ($0 as NSString).pathExtension.lowercased() == "deskcap" }) ?? true else { throw CaptureError.message(L10n.text("素材文件类型无效。")) }
            let files = [record.filename] + (includeProjects ? (record.projectFilename.map { [$0] } ?? []) : [])
            for name in files {
                try Task.checkCancellation()
                guard name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { throw CaptureError.message(L10n.text("素材路径无效。")) }
                let source = directory.appendingPathComponent(name)
                let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true, let size = properties.fileSize else { throw CaptureError.message(L10n.text("素材缺失或不是普通文件。")) }
                total += Int64(size)
                guard total <= 4_000_000_000 else { throw CaptureError.message(L10n.text("一次批量导出最多4GB。")) }
                let target = stage.appendingPathComponent(String(format: "capture-%04d", index + 1)).appendingPathExtension(source.pathExtension)
                guard !manager.fileExists(atPath: target.path) else { throw CaptureError.message(L10n.text("导出文件扩展名冲突。")) }
                try manager.copyItem(at: source, to: target)
            }
        }
        try beforeCommit?(); try Task.checkCancellation()
        try manager.moveItem(at: stage, to: destination)
    }
}
