import Foundation
import CryptoKit
import Darwin

actor HistoryWriteGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if !held { held = true; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in waiters.append((id, continuation)) }
        }, onCancel: { Task { await self.cancel(id) } })
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        let waiter = waiters.remove(at: index); waiter.1.resume(throwing: CancellationError())
    }
    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }
}

struct HistoryArchive: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let records: [CaptureRecord]
}
struct HistoryArchiveSummary: Identifiable {
    let id: UUID
    let createdAt: Date
    let count: Int
}
struct HistoryLegacyResult { let records: [CaptureRecord]; let warning: String? }
private struct HistoryFileMove: Codable { let from: String; let to: String }
private struct HistoryJournal: Codable {
    let id: UUID
    let before: String
    let after: String
    let moves: [HistoryFileMove]
    let cleanupOnCommit: [String]
    let cleanupOnRollback: [String]
}

/// All production asynchronous mutations share this file lock and recover the
/// preceding journal before reading the index. A journal never contains absolute paths.
enum HistoryTransactions {
    private static let manager = FileManager.default
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func indexData(_ directory: URL) throws -> Data {
        let file = try url("history.json", directory: directory)
        guard manager.fileExists(atPath: file.path) else { return Data("[]".utf8) }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64_000_000 else { throw CaptureError.message(L10n.text("历史索引超过64MB，未修改。")) }
        return try Data(contentsOf: file)
    }
    private static func decode(_ data: Data) throws -> [CaptureRecord] {
        try validatedRecords(JSONDecoder().decode([CaptureRecord].self, from: data))
    }
    static func validatedRecords(_ records: [CaptureRecord]) throws -> [CaptureRecord] {
        guard records.count <= 100_000, Set(records.map(\.id)).count == records.count else { throw CaptureError.message(L10n.text("历史索引标识重复或数量超限。")) }
        let allFiles = records.flatMap { [$0.filename] + ($0.projectFilename.map { [$0] } ?? []) }
        guard Set(allFiles).count == allFiles.count else { throw CaptureError.message(L10n.text("历史记录共享同一文件，未修改任何素材。")) }
        for record in records {
            guard (record.filename as NSString).pathExtension.lowercased() == "png",
                  record.projectFilename.map({ ($0 as NSString).pathExtension.lowercased() == "deskcap" }) ?? true else { throw CaptureError.message(L10n.text("历史文件类型无效。")) }
            for name in [record.filename] + (record.projectFilename.map { [$0] } ?? []) {
                guard safe(name), !name.contains("/"), !name.hasPrefix(".") else { throw CaptureError.message(L10n.text("历史文件路径无效，未修改。")) }
            }
        }
        return records
    }
    private static func safe(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 600 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func url(_ path: String, directory: URL) throws -> URL {
        guard safe(path) else { throw CaptureError.message(L10n.text("事务路径无效，已保留恢复文件。")) }
        var location = directory
        for part in path.split(separator: "/") {
            location.appendPathComponent(String(part))
            if manager.fileExists(atPath: location.path), (try location.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false) {
                throw CaptureError.message(L10n.text("事务路径不接受符号链接，原文件已保留。"))
            }
        }
        return location
    }
    private static func locked<T>(_ directory: URL, work: () throws -> T) throws -> T {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".history.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.message(L10n.text("无法打开历史事务锁。")) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CaptureError.message(L10n.text("另一进程正在更新历史，未修改本次数据。")) }
        defer { flock(fd, LOCK_UN) }
        try recoverLocked(directory)
        try Task.checkCancellation(); return try work()
    }
    private static func clean(_ paths: [String], directory: URL) throws {
        for path in paths {
            let parts = path.split(separator: "/")
            let incoming = parts.count == 1 && path.hasPrefix(".incoming-") && UUID(uuidString: String(path.dropFirst(10))) != nil
            let archive = parts.count == 2 && parts[0] == ".history-archive" && UUID(uuidString: String(parts[1])) != nil
            guard incoming || archive else { throw CaptureError.message(L10n.text("恢复目录范围无效，未清理。")) }
            let target = try url(path, directory: directory)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        }
    }
    private static func recoverLocked(_ directory: URL) throws {
        let file = directory.appendingPathComponent(".history-transaction.json")
        guard manager.fileExists(atPath: file.path) else { return }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64_000_000 else { throw CaptureError.message(L10n.text("恢复日志超过64MB，原文件已保留。")) }
        let journal = try JSONDecoder().decode(HistoryJournal.self, from: Data(contentsOf: file))
        func dataPath(_ path: String) -> Bool {
            guard safe(path) else { return false }
            let parts = path.split(separator: "/")
            guard let name = parts.last, !name.hasPrefix("."), ["png", "deskcap"].contains((String(name) as NSString).pathExtension.lowercased()) else { return false }
            if parts.count == 1 { return true }
            if parts.count == 2 { return parts[0].hasPrefix(".incoming-") && UUID(uuidString: String(parts[0].dropFirst(10))) != nil }
            return parts.count == 3 && parts[0] == ".history-archive" && UUID(uuidString: String(parts[1])) != nil
        }
        guard journal.moves.count <= 200_000, journal.cleanupOnCommit.count <= 2, journal.cleanupOnRollback.count <= 2,
              [journal.before, journal.after].allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }),
              journal.moves.allSatisfy({ dataPath($0.from) && dataPath($0.to) }),
              Set(journal.moves.map(\.from)).count == journal.moves.count, Set(journal.moves.map(\.to)).count == journal.moves.count else { throw CaptureError.message(L10n.text("恢复日志超出范围，原文件已保留。")) }
        let current = digest(try indexData(directory))
        if current == journal.after {
            try clean(journal.cleanupOnCommit, directory: directory)
        } else if current == journal.before {
            for move in journal.moves.reversed() {
                let from = try url(move.from, directory: directory), to = try url(move.to, directory: directory)
                let a = manager.fileExists(atPath: from.path), b = manager.fileExists(atPath: to.path)
                if b && !a { try manager.moveItem(at: to, to: from) }
                else if a && !b { continue }
                else { throw CaptureError.message(L10n.text("恢复遇到文件冲突或缺失，日志与恢复目录均已保留。")) }
            }
            try clean(journal.cleanupOnRollback, directory: directory)
        } else { throw CaptureError.message(L10n.text("历史在事务中被另一版本修改，恢复日志与所有文件已保留，未覆盖索引。")) }
        try manager.removeItem(at: file)
    }
    private static func commit(_ directory: URL, old: Data, records: [CaptureRecord], moves: [HistoryFileMove],
                               cleanupOnCommit: [String], cleanupOnRollback: [String], beforeIndex: (() throws -> Void)?) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let next = try encoder.encode(records)
        _ = try decode(next)
        guard next.count <= 64_000_000 else { throw CaptureError.message(L10n.text("新历史索引超过64MB。")) }
        let journal = HistoryJournal(id: UUID(), before: digest(old), after: digest(next), moves: moves,
            cleanupOnCommit: cleanupOnCommit, cleanupOnRollback: cleanupOnRollback)
        let file = directory.appendingPathComponent(".history-transaction.json")
        for move in moves {
            let from = try url(move.from, directory: directory), to = try url(move.to, directory: directory)
            guard manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) else { throw CaptureError.message(L10n.text("批量文件缺失或目标已存在，尚未移动。")) }
        }
        let journalData = try encoder.encode(journal)
        guard journalData.count <= 64_000_000 else { throw CaptureError.message(L10n.text("批次恢复日志超过64MB，未移动文件。")) }
        try journalData.write(to: file, options: .atomic)
        do {
            for move in moves {
                try Task.checkCancellation()
                let from = try url(move.from, directory: directory), to = try url(move.to, directory: directory)
                guard manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) else { throw CaptureError.message(L10n.text("批量文件缺失或目标已存在，未覆盖。")) }
                try manager.moveItem(at: from, to: to)
            }
            try beforeIndex?(); try Task.checkCancellation()
            guard digest(try indexData(directory)) == journal.before else { throw CaptureError.message(L10n.text("历史已由其他操作改变，未覆盖索引。")) }
            try next.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
        } catch {
            do { try recoverLocked(directory) }
            catch { throw CaptureError.message(L10n.text("事务尚未完成，日志和文件已保留：\(error.localizedDescription)")) }
            throw error
        }
        // The index rename is the commit boundary; cleanup can be retried from
        // the journal and must not turn a successful commit into a false failure.
        try? recoverLocked(directory)
    }
    static func load(_ directory: URL) throws -> [CaptureRecord] { try locked(directory) { try decode(indexData(directory)) } }
    static func legacyMutation(_ directory: URL, preferences: UserDefaults, _ work: (CaptureStore) throws -> Void) throws -> HistoryLegacyResult {
        try locked(directory) {
            let store = CaptureStore(directory: directory, pruneOnInit: false, preferences: preferences)
            try work(store); return HistoryLegacyResult(records: store.records, warning: store.transactionError)
        }
    }
    static func repairLegacy(_ directory: URL, original: Data, recovered: [CaptureRecord]) throws {
        try locked(directory) {
            let current = try indexData(directory)
            guard current == original else { _ = try decode(current); return }
            _ = try decode(JSONEncoder().encode(recovered))
            try original.write(to: directory.appendingPathComponent("history-recovery-\(UUID()).json"), options: .atomic)
            try Task.checkCancellation()
            try JSONEncoder().encode(recovered).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
        }
    }
    static func append(_ record: CaptureRecord, incoming: URL, directory: URL, beforeIndex: (() throws -> Void)? = nil) throws -> [CaptureRecord] {
        try locked(directory) {
            let old = try indexData(directory); var records = try decode(old)
            guard !records.contains(where: { $0.id == record.id }), incoming.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  incoming.lastPathComponent.hasPrefix(".incoming-") else { throw CaptureError.message(L10n.text("新增截图事务标识无效。")) }
            let names = [record.filename] + (record.projectFilename.map { [$0] } ?? [])
            let moves = names.map { HistoryFileMove(from: incoming.lastPathComponent + "/" + $0, to: $0) }
            records.insert(record, at: 0)
            try commit(directory, old: old, records: records, moves: moves, cleanupOnCommit: [incoming.lastPathComponent], cleanupOnRollback: [incoming.lastPathComponent], beforeIndex: beforeIndex)
            return records
        }
    }
    static func setText(_ text: String, id: UUID, directory: URL, onlyIfMissing: Bool = false) throws -> [CaptureRecord] {
        try locked(directory) {
            var records = try decode(indexData(directory))
            guard let index = records.firstIndex(where: { $0.id == id }) else { return records }
            if onlyIfMissing, records[index].recognizedText != nil { return records }
            records[index].recognizedText = text
            let data = try JSONEncoder().encode(records)
            guard data.count <= 64_000_000 else { throw CaptureError.message(L10n.text("文字保存后索引超过64MB。")) }
            try Task.checkCancellation(); try data.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
            return records
        }
    }
    /// Permanent cleanup uses the same index-rename commit boundary as recoverable
    /// removals. Missing indexed files are tolerated; unrelated files are untouched.
    static func permanentlyRemove(directory: URL, olderThan cutoff: Date? = nil,
                                  beforeIndex: (() throws -> Void)? = nil) throws -> HistoryLegacyResult {
        try locked(directory) {
            let old = try indexData(directory), records = try decode(old)
            // Keep the predicate explicit: nil means an explicitly requested clear-all.
            let selected = cutoff.map { date in records.filter { $0.createdAt < date } } ?? records
            guard !selected.isEmpty else { return HistoryLegacyResult(records: records, warning: nil) }
            let ids = Set(selected.map(\.id))
            let remaining = records.filter { !ids.contains($0.id) }
            let folder = ".incoming-\(UUID())"
            let stage = try url(folder, directory: directory)
            try manager.createDirectory(at: stage, withIntermediateDirectories: true)
            defer {
                if !manager.fileExists(atPath: directory.appendingPathComponent(".history-transaction.json").path) {
                    try? manager.removeItem(at: stage)
                }
            }
            var moves: [HistoryFileMove] = []
            for record in selected {
                try Task.checkCancellation()
                for name in [record.filename] + (record.projectFilename.map { [$0] } ?? []) {
                    let original = try url(name, directory: directory)
                    if manager.fileExists(atPath: original.path) {
                        guard try original.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CaptureError.message(L10n.text("待清理历史不是普通文件，未修改索引。")) }
                        moves.append(.init(from: name, to: folder + "/" + name))
                    }
                }
            }
            try commit(directory, old: old, records: remaining, moves: moves,
                       cleanupOnCommit: [folder], cleanupOnRollback: [folder], beforeIndex: beforeIndex)
            let pending = manager.fileExists(atPath: directory.appendingPathComponent(".history-transaction.json").path)
            return HistoryLegacyResult(records: remaining, warning: pending ? L10n.text("历史索引已更新，清理日志和暂存文件保留，下一次历史操作将重试清理。") : nil)
        }
    }
    static func remove(_ ids: Set<UUID>, directory: URL, beforeIndex: (() throws -> Void)? = nil) throws -> ([CaptureRecord], HistoryArchive) {
        try locked(directory) {
            let old = try indexData(directory), records = try decode(old)
            let removed = records.filter { ids.contains($0.id) }
            guard !removed.isEmpty, removed.count <= 1000, removed.count == ids.count else { throw CaptureError.message(L10n.text("批次需包含1–1000条仍在历史中的素材。")) }
            let archive = HistoryArchive(id: UUID(), createdAt: Date(), records: removed)
            let folder = ".history-archive/\(archive.id)"
            let names = removed.flatMap { [$0.filename] + ($0.projectFilename.map { [$0] } ?? []) }
            guard Set(names).count == names.count else { throw CaptureError.message(L10n.text("多个记录引用相同文件，未移除。")) }
            let folderURL = try url(folder, directory: directory)
            try manager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            var keep = false
            defer {
                if !keep, !manager.fileExists(atPath: directory.appendingPathComponent(".history-transaction.json").path) { try? manager.removeItem(at: folderURL) }
            }
            try JSONEncoder().encode(archive).write(to: folderURL.appendingPathComponent("archive.json"), options: .atomic)
            let remaining = records.filter { !ids.contains($0.id) }
            do {
                try commit(directory, old: old, records: remaining, moves: names.map { .init(from: $0, to: folder + "/" + $0) },
                           cleanupOnCommit: [], cleanupOnRollback: [folder], beforeIndex: beforeIndex)
            } catch {
                if !manager.fileExists(atPath: directory.appendingPathComponent(".history-transaction.json").path),
                   (try? digest(indexData(directory))) == digest(old) { try? manager.removeItem(at: directory.appendingPathComponent(folder)) }
                throw error
            }
            keep = true; return (remaining, archive)
        }
    }
    static func archives(_ directory: URL) throws -> [HistoryArchiveSummary] {
        try locked(directory) {
            let root = try url(".history-archive", directory: directory)
            guard manager.fileExists(atPath: root.path) else { return [] }
            let currentIDs = Set(try decode(indexData(directory)).map(\.id))
            return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { folder -> HistoryArchiveSummary? in
                try Task.checkCancellation()
                let file = folder.appendingPathComponent("archive.json")
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64_000_000 else { throw CaptureError.message(L10n.text("恢复批次超过64MB，文件已保留。")) }
                let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: file))
                guard archive.id.uuidString == folder.lastPathComponent, archive.records.count <= 1000 else { throw CaptureError.message(L10n.text("恢复批次格式无效，文件已保留。")) }
                _ = try decode(JSONEncoder().encode(archive.records))
                if archive.records.allSatisfy({ currentIDs.contains($0.id) }) {
                    let names = try manager.contentsOfDirectory(atPath: folder.path)
                    if names == ["archive.json"] {
                        // Process interruption before the journal was published:
                        // only a manifest exists; no source file was moved.
                        try manager.removeItem(at: folder); return nil
                    }
                }
                return HistoryArchiveSummary(id: archive.id, createdAt: archive.createdAt, count: archive.records.count)
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    static func restore(_ id: UUID, directory: URL, beforeIndex: (() throws -> Void)? = nil) throws -> [CaptureRecord] {
        try locked(directory) {
            let folder = ".history-archive/\(id)"
            let manifest = try url(folder + "/archive.json", directory: directory)
            guard (try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64_000_000 else { throw CaptureError.message(L10n.text("恢复批次超过64MB。")) }
            let archive = try JSONDecoder().decode(HistoryArchive.self, from: Data(contentsOf: manifest))
            guard archive.id == id, !archive.records.isEmpty, archive.records.count <= 1000 else { throw CaptureError.message(L10n.text("恢复批次格式无效。")) }
            _ = try decode(JSONEncoder().encode(archive.records))
            let old = try indexData(directory), current = try decode(old), ids = Set(current.map(\.id))
            guard archive.records.allSatisfy({ !ids.contains($0.id) }) else { throw CaptureError.message(L10n.text("历史中已有相同标识，未覆盖。")) }
            let names = archive.records.flatMap { [$0.filename] + ($0.projectFilename.map { [$0] } ?? []) }
            let records = (current + archive.records).sorted { $0.createdAt > $1.createdAt }
            try commit(directory, old: old, records: records, moves: names.map { .init(from: folder + "/" + $0, to: $0) }, cleanupOnCommit: [folder], cleanupOnRollback: [], beforeIndex: beforeIndex)
            return records
        }
    }
}
