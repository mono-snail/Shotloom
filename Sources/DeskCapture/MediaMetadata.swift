import Foundation
import Combine
import Darwin

struct MediaMetadata: Codable, Equatable {
    var title = ""
    var tags: [String] = []
    var favorite = false
    var collections = Set<UUID>()
    func validated() throws -> Self {
        var normalized = self
        normalized.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.title.count <= 120, !normalized.title.contains(where: \.isNewline), normalized.tags.count <= 20,
              normalized.tags.allSatisfy({ !$0.isEmpty && $0.count <= 32 && !$0.contains(where: \.isNewline) }),
              Set(normalized.tags.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }).count == normalized.tags.count,
              collections.count <= 20 else { throw CaptureError.message(L10n.text("标题最多120字，标签最多20个且每个1–32字，不可重复；集合最多20个。")) }
        return normalized
    }
}
struct MediaCollection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}
struct MediaMetadataSnapshot: Codable {
    var version = 1
    var sequence = 0
    var entries: [String: MediaMetadata] = [:]
    var collections: [MediaCollection] = []
    func validate() throws {
        guard version == 1, (0...1_000_000_000).contains(sequence), entries.count <= 20_000, collections.count <= 200,
              Set(collections.map(\.id)).count == collections.count,
              collections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 40 }),
              Set(collections.map { $0.name.lowercased() }).count == collections.count else { throw CaptureError.message(L10n.text("素材分类索引无效或超出容量，原索引已保留。")) }
        let known = Set(collections.map(\.id))
        for (key, value) in entries {
            guard MediaMetadataKey.valid(key), value.collections.isSubset(of: known) else { throw CaptureError.message(L10n.text("素材标识或集合引用无效，原索引已保留。")) }
            guard value == (try value.validated()) else { throw CaptureError.message(L10n.text("分类字段格式异常，原索引已保留。")) }
        }
    }
}
enum MediaMetadataKey {
    static func capture(_ id: UUID) -> String { "capture:" + id.uuidString }
    static func recording(_ folder: URL) -> String { "recording:" + folder.lastPathComponent }
    static func valid(_ value: String) -> Bool {
        if value.hasPrefix("capture:") { return UUID(uuidString: String(value.dropFirst(8))) != nil }
        guard value.hasPrefix("recording:") else { return false }
        let name = String(value.dropFirst(10))
        return !name.isEmpty && name.count <= 200 && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

actor MediaMetadataRepository {
    static let shared = MediaMetadataRepository()
    let directory: URL
    private let beforeCommit: (() throws -> Void)?
    init(directory: URL? = nil, beforeCommit: (() throws -> Void)? = nil) {
        let diagnostic = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("media-metadata") }
        self.directory = directory ?? diagnostic ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskCapture/MediaMetadata")
        self.beforeCommit = beforeCommit
    }
    private func locked<T>(_ work: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("metadata.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CaptureError.message(L10n.text("无法打开分类索引锁。")) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CaptureError.message(L10n.text("分类索引正在由另一进程更新，请稍后重试。")) }
        defer { flock(descriptor, LOCK_UN) }
        return try work()
    }
    private func read() throws -> MediaMetadataSnapshot {
        let file = directory.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_000_000 else { throw CaptureError.message(L10n.text("分类索引超过16MB，原文件已保留。")) }
        let snapshot = try JSONDecoder().decode(MediaMetadataSnapshot.self, from: Data(contentsOf: file))
        try snapshot.validate(); return snapshot
    }
    private func write(_ value: MediaMetadataSnapshot) throws {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 16_000_000 else { throw CaptureError.message(L10n.text("分类索引超过16MB，未保存。")) }
        try beforeCommit?(); try Task.checkCancellation()
        try data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }
    func snapshot() throws -> MediaMetadataSnapshot { try locked { try read() } }
    func classifyBatch(_ keys: Set<String>, change: MediaBatchClassification, expected: [String: MediaMetadata]) throws -> MediaMetadataSnapshot {
        try locked {
            guard !keys.isEmpty, keys.count <= 1000, keys.allSatisfy(MediaMetadataKey.valid) else { throw CaptureError.message(L10n.text("一次分类选择1–1000条素材。")) }
            var state = try read()
            if let collection = change.addCollection {
                guard state.collections.contains(where: { $0.id == collection }) else { throw CaptureError.message(L10n.text("集合已被移除。")) }
            }
            for key in keys {
                let old = state.entries[key] ?? .init()
                guard old == expected[key] else { throw CaptureError.message(L10n.text("批次中有分类已改变，全部保持原状，请刷新后重试。")) }
                var updated = old
                updated.tags.removeAll { value in change.removeTags.contains { $0.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } }
                for tag in change.addTags where !updated.tags.contains(where: { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { updated.tags.append(tag) }
                if let collection = change.addCollection { updated.collections.insert(collection) }
                if let favorite = change.favorite { updated.favorite = favorite }
                state.entries[key] = try updated.validated()
            }
            state.sequence += 1; try write(state); return state
        }
    }
    func save(key: String, value: MediaMetadata, expected: MediaMetadata) throws -> MediaMetadataSnapshot {
        try locked {
            var state = try read()
            guard MediaMetadataKey.valid(key), (state.entries[key] ?? .init()) == expected else { throw CaptureError.message(L10n.text("分类已被其他操作更改，请重新打开后编辑。")) }
            state.entries[key] = try value.validated(); state.sequence += 1
            try write(state); return state
        }
    }
    func addCollection(_ name: String) throws -> MediaMetadataSnapshot {
        try locked {
            var state = try read()
            state.collections.append(.init(name: name.trimmingCharacters(in: .whitespacesAndNewlines))); state.sequence += 1
            try write(state); return state
        }
    }
    func toggleFavorite(_ key: String) throws -> MediaMetadataSnapshot {
        try locked {
            guard MediaMetadataKey.valid(key) else { throw CaptureError.message(L10n.text("素材标识无效。")) }
            var state = try read()
            var value = state.entries[key] ?? MediaMetadata(); value.favorite.toggle()
            state.entries[key] = value; state.sequence += 1
            try write(state); return state
        }
    }
    func renameCollection(_ id: UUID, to name: String) throws -> MediaMetadataSnapshot {
        try locked {
            var state = try read()
            guard let index = state.collections.firstIndex(where: { $0.id == id }) else { throw CaptureError.message(L10n.text("集合已不存在。")) }
            state.collections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); state.sequence += 1
            try write(state); return state
        }
    }
    func removeCollection(_ id: UUID) throws -> MediaMetadataSnapshot {
        try locked {
            var state = try read(); state.collections.removeAll { $0.id == id }
            for key in Array(state.entries.keys) { state.entries[key]?.collections.remove(id) }
            state.sequence += 1; try write(state); return state
        }
    }
}

@MainActor final class MediaMetadataStore: ObservableObject {
    static let shared = MediaMetadataStore()
    @Published private(set) var snapshot = MediaMetadataSnapshot()
    @Published var error: String?
    let repository: MediaMetadataRepository
    init(repository: MediaMetadataRepository = .shared) { self.repository = repository }
    func value(_ key: String) -> MediaMetadata { snapshot.entries[key] ?? .init() }
    private func accept(_ value: MediaMetadataSnapshot) { if value.sequence >= snapshot.sequence { snapshot = value }; error = nil }
    func reload() async { do { accept(try await repository.snapshot()) } catch { self.error = error.localizedDescription } }
    func save(key: String, value: MediaMetadata, expected: MediaMetadata) async throws {
        accept(try await repository.save(key: key, value: value, expected: expected))
    }
    func addCollection(_ name: String) async throws { accept(try await repository.addCollection(name)) }
    func renameCollection(_ id: UUID, name: String) async throws { accept(try await repository.renameCollection(id, to: name)) }
    func removeCollection(_ id: UUID) async throws { accept(try await repository.removeCollection(id)) }
    func classifyBatch(_ keys: Set<String>, change: MediaBatchClassification, expected: [String: MediaMetadata]) async throws {
        accept(try await repository.classifyBatch(keys, change: change, expected: expected))
    }
    func toggleFavorite(_ key: String) async {
        do { accept(try await repository.toggleFavorite(key)) } catch { self.error = error.localizedDescription }
    }
}
