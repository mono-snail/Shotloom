import Foundation

struct MediaQueryKey: Hashable {
    let text: String
    let revision: UUID
    let metadataSequence: Int
    // A new attempt reruns an unchanged query after a transient read failure.
    var retry: UUID? = nil
}
struct CaptureSearchStatistics {
    let documents: Int
    let postings: Int
    let foldedBytes: Int
    let indexed: Bool
}
actor CaptureSearchIndex {
    private struct Document {
        let id: UUID
        let fields: [String]
        let tags: Set<String>
        let collections: Set<String>
        let favorite: Bool
    }
    private var version: UUID?
    private var sequence = -1
    private var documents: [Document] = []
    private var postings: [UInt32: [Int]] = [:]
    private var foldedBytes = 0
    private var postingCount = 0
    private var indexed = false
    private let postingBudget: Int
    private let mediaType: String
    init(postingBudget: Int = 2_000_000, mediaType: String = "image") { self.postingBudget = max(0, postingBudget); self.mediaType = mediaType }
    private static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping }
    private static func grams(_ value: String, limit: Int = 16_384) -> Set<UInt32>? {
        var result = Set<UInt32>(), rolling: UInt32 = 0, count = 0
        for byte in value.utf8 {
            rolling = ((rolling << 8) | UInt32(byte)) & 0xFFFFFF; count += 1
            if count >= 3 { result.insert(rolling) }
            if result.count > limit { return nil }
        }
        return result
    }
    private func rebuild(_ records: [CaptureRecord], metadata: MediaMetadataSnapshot, version: UUID, titles: [UUID: String]) throws {
        let names = Dictionary(uniqueKeysWithValues: metadata.collections.map { ($0.id, Self.fold($0.name)) })
        var next: [Document] = [], inverted: [UInt32: [Int]] = [:], bytes = 0, count = 0, enabled = postingBudget > 0
        next.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            let value = metadata.entries[MediaMetadataKey.capture(record.id)] ?? .init()
            let fields = ([titles[record.id] ?? record.title, value.title, record.recognizedText ?? ""] + value.tags).map(Self.fold)
            bytes += fields.reduce(0) { $0 + $1.utf8.count }
            guard bytes <= 128_000_000 else { throw CaptureError.message(L10n.text("搜索文本超过128MB预算，本次索引未完成。")) }
            next.append(.init(id: record.id, fields: fields, tags: Set(value.tags.map(Self.fold)), collections: Set(value.collections.compactMap { names[$0] }), favorite: value.favorite))
            if enabled {
                var keys = Set<UInt32>()
                for field in fields {
                    guard let grams = Self.grams(field) else { enabled = false; break }
                    keys.formUnion(grams)
                    if keys.count > 16_384 { enabled = false; break }
                }
                if enabled && count + keys.count <= postingBudget {
                    for key in keys { inverted[key, default: []].append(index) }
                    count += keys.count
                } else { enabled = false }
                if !enabled { inverted = [:]; count = 0 }
            }
        }
        try Task.checkCancellation()
        documents = next; postings = inverted; foldedBytes = bytes; postingCount = count; indexed = enabled
        self.version = version; sequence = metadata.sequence
    }
    func search(_ records: [CaptureRecord], query: String, metadata: MediaMetadataSnapshot, version: UUID, titles: [UUID: String] = [:]) throws -> Set<UUID> {
        let parsed = try MediaSearchQuery(query)
        if self.version != version || sequence != metadata.sequence { try rebuild(records, metadata: metadata, version: version, titles: titles) }
        let terms = parsed.terms.map { ($0.field, Self.fold($0.value), $0.excluded) }
        var candidates: Set<Int>?
        if indexed {
            for (field, value, excluded) in terms where field == .text && !excluded && value.utf8.count >= 3 {
                guard let grams = Self.grams(value) else { continue }
                let lists = grams.map { postings[$0] ?? [] }.sorted { $0.count < $1.count }
                for list in lists {
                    if let current = candidates { candidates = current.intersection(list) }
                    else { candidates = Set(list) }
                    if candidates?.isEmpty == true { return [] }
                }
            }
        }
        var result = Set<UUID>()
        let indices = candidates.map { Array($0) } ?? Array(documents.indices)
        for index in indices {
            try Task.checkCancellation()
            let document = documents[index]
            let matches = terms.allSatisfy { field, value, excluded in
                let found: Bool
                switch field {
                case .text: found = document.fields.contains { $0.contains(value) }
                case .tag: found = document.tags.contains(value)
                case .collection: found = document.collections.contains(value)
                case .favorite: found = document.favorite
                case .type: found = value == mediaType
                }
                return excluded ? !found : found
            }
            if matches { result.insert(document.id) }
        }
        return result
    }
    func statistics() -> CaptureSearchStatistics { .init(documents: documents.count, postings: postingCount, foldedBytes: foldedBytes, indexed: indexed) }
    func matchingRecords(_ records: [CaptureRecord], query: String, metadata: MediaMetadataSnapshot, version: UUID) throws -> [CaptureRecord] {
        let ids = try search(records, query: query, metadata: metadata, version: version)
        return records.filter { ids.contains($0.id) }
    }
}
