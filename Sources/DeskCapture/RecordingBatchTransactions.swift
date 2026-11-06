import Foundation
import Darwin

struct RecordingArchive: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let folders: [String]
}
private struct RecordingMove: Codable { let from: String; let to: String }
private struct RecordingJournal: Codable {
    var committed = false
    let moves: [RecordingMove]
    let cleanupOnCommit: String?
    let cleanupOnRollback: String?
}
enum RecordingBatchTransactions {
    private static let manager = FileManager.default
    private static func folderName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private static func location(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (parts.count == 1 && folderName(path)) ||
              (parts.count == 3 && parts[0] == ".recordings-archive" && UUID(uuidString: String(parts[1])) != nil && folderName(String(parts[2]))) else {
            throw CaptureError.message(L10n.text("录屏事务路径无效，未修改文件。"))
        }
        var url = root
        for part in parts {
            url.appendPathComponent(String(part))
            if manager.fileExists(atPath: url.path), (try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) { throw CaptureError.message(L10n.text("录屏事务路径不接受符号链接。")) }
        }
        return url
    }
    private static func archiveFolder(_ id: UUID, root: URL) throws -> URL {
        let base = root.appendingPathComponent(".recordings-archive")
        if manager.fileExists(atPath: base.path), (try base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) { throw CaptureError.message(L10n.text("恢复根目录不是普通目录。")) }
        return base.appendingPathComponent(id.uuidString)
    }
    private static func cleanup(_ path: String?, root: URL) throws {
        guard let path else { return }
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == ".recordings-archive", let id = UUID(uuidString: String(parts[1])) else { throw CaptureError.message(L10n.text("录屏事务清理范围无效。")) }
        let folder = try archiveFolder(id, root: root)
        guard manager.fileExists(atPath: folder.path) else { return }
        let names = try manager.contentsOfDirectory(atPath: folder.path)
        guard names.isEmpty || names == ["archive.json"] else { throw CaptureError.message(L10n.text("恢复目录仍有素材，已保留目录及日志。")) }
        try manager.removeItem(at: folder)
    }
    private static func recover(_ root: URL) throws {
        let file = root.appendingPathComponent(".recordings-transaction.json")
        guard manager.fileExists(atPath: file.path) else { return }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_000_000 else { throw CaptureError.message(L10n.text("录屏恢复日志超过1MB。")) }
        let journal = try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: file))
        guard journal.moves.count <= 1000, Set(journal.moves.map(\.from)).count == journal.moves.count, Set(journal.moves.map(\.to)).count == journal.moves.count else { throw CaptureError.message(L10n.text("录屏恢复日志无效。")) }
        if journal.committed { try cleanup(journal.cleanupOnCommit, root: root) }
        else {
            for move in journal.moves.reversed() {
                let from = try location(move.from, root: root), to = try location(move.to, root: root)
                let a = manager.fileExists(atPath: from.path), b = manager.fileExists(atPath: to.path)
                if b && !a { try manager.moveItem(at: to, to: from) }
                else if a && !b { continue }
                else { throw CaptureError.message(L10n.text("录屏恢复发现冲突或缺失，原文件与日志均已保留。")) }
            }
            try cleanup(journal.cleanupOnRollback, root: root)
        }
        try manager.removeItem(at: file)
    }
    static func snapshot<T>(_ root: URL, _ work: () throws -> T) throws -> T {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".recordings.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.message(L10n.text("无法打开录屏事务锁。")) }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CaptureError.message(L10n.text("录屏素材正在由其他操作更新，请稍后重试。")) }
        defer { flock(fd, LOCK_UN) }
        try recover(root); try Task.checkCancellation(); return try work()
    }
    private static func commit(_ journal: RecordingJournal, root: URL, beforeCommit: (() throws -> Void)?) throws {
        let file = root.appendingPathComponent(".recordings-transaction.json")
        var leases: [RecordingSessionLease] = []
        defer { withExtendedLifetime(leases) {} }
        for move in journal.moves {
            let source = try location(move.from, root: root), target = try location(move.to, root: root)
            if manager.fileExists(atPath: RecordingSessionJournal.url(source).path) { leases.append(try RecordingSessionLease(directory: source)) }
            guard (try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !manager.fileExists(atPath: target.path) else { throw CaptureError.message(L10n.text("录屏目录缺失或目标已有同名目录，未覆盖。")) }
        }
        try JSONEncoder().encode(journal).write(to: file, options: .atomic)
        do {
            for move in journal.moves { try Task.checkCancellation(); try manager.moveItem(at: location(move.from, root: root), to: location(move.to, root: root)) }
            try beforeCommit?(); try Task.checkCancellation()
            var complete = journal; complete.committed = true
            try JSONEncoder().encode(complete).write(to: file, options: .atomic)
        } catch {
            do { try recover(root) } catch { throw CaptureError.message(L10n.text("录屏事务需继续恢复，目录与日志已保留：\(error.localizedDescription)")) }
            throw error
        }
        try? recover(root)
    }
    static func remove(_ entries: [RecordingLibraryEntry], root: URL, beforeCommit: (() throws -> Void)? = nil) throws -> RecordingArchive {
        try snapshot(root) {
            let names = entries.map { $0.id.lastPathComponent }
            guard !names.isEmpty, names.count <= 1000, Set(names).count == names.count,
                  entries.allSatisfy({ $0.id.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL }), names.allSatisfy(folderName) else { throw CaptureError.message(L10n.text("请选择本机录屏库中的1–1000条素材。")) }
            let archive = RecordingArchive(id: UUID(), createdAt: Date(), folders: names)
            let folder = try archiveFolder(archive.id, root: root), relative = ".recordings-archive/\(archive.id)"
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            var keep = false
            defer { if !keep && !manager.fileExists(atPath: root.appendingPathComponent(".recordings-transaction.json").path) { try? manager.removeItem(at: folder) } }
            try JSONEncoder().encode(archive).write(to: folder.appendingPathComponent("archive.json"), options: .atomic)
            let journal = RecordingJournal(moves: names.map { .init(from: $0, to: relative + "/" + $0) }, cleanupOnCommit: nil, cleanupOnRollback: relative)
            try commit(journal, root: root, beforeCommit: beforeCommit); keep = true; return archive
        }
    }
    static func archives(_ root: URL) throws -> [RecordingArchive] {
        try snapshot(root) {
            let base = root.appendingPathComponent(".recordings-archive")
            guard manager.fileExists(atPath: base.path) else { return [] }
            guard (try base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CaptureError.message(L10n.text("恢复目录不接受符号链接。")) }
            return try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { folder -> RecordingArchive? in
                try Task.checkCancellation()
                let file = folder.appendingPathComponent("archive.json")
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 256_000 else { throw CaptureError.message(L10n.text("录屏恢复清单超过256KB。")) }
                let archive = try JSONDecoder().decode(RecordingArchive.self, from: Data(contentsOf: file))
                guard archive.id.uuidString == folder.lastPathComponent, !archive.folders.isEmpty, archive.folders.count <= 1000,
                      Set(archive.folders).count == archive.folders.count, archive.folders.allSatisfy(folderName) else { throw CaptureError.message(L10n.text("录屏恢复清单无效。")) }
                if try manager.contentsOfDirectory(atPath: folder.path) == ["archive.json"], archive.folders.allSatisfy({ manager.fileExists(atPath: root.appendingPathComponent($0).path) }) {
                    try manager.removeItem(at: folder); return nil
                }
                return archive
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    static func restore(_ archive: RecordingArchive, root: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        try snapshot(root) {
            let folder = try archiveFolder(archive.id, root: root), file = folder.appendingPathComponent("archive.json")
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 256_000 else { throw CaptureError.message(L10n.text("录屏恢复清单超过256KB。")) }
            let current = try JSONDecoder().decode(RecordingArchive.self, from: Data(contentsOf: file))
            guard current.id == archive.id, current.folders == archive.folders, !current.folders.isEmpty, current.folders.count <= 1000,
                  Set(current.folders).count == current.folders.count, current.folders.allSatisfy(folderName) else { throw CaptureError.message(L10n.text("录屏恢复批次已改变。")) }
            let relative = ".recordings-archive/\(archive.id)"
            try commit(.init(moves: current.folders.map { .init(from: relative + "/" + $0, to: $0) }, cleanupOnCommit: relative, cleanupOnRollback: nil), root: root, beforeCommit: beforeCommit)
        }
    }
}
