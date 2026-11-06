import Foundation

struct MediaSearchQuery {
    enum Field: Equatable { case text, tag, collection, favorite, type }
    struct Term { let field: Field; let value: String; let excluded: Bool }
    let terms: [Term]
    init(_ query: String) throws {
        guard query.count <= 2048 else { throw CaptureError.message(L10n.text("搜索最多2048字。")) }
        var tokens: [String] = [], current = "", quoted = false
        for char in query {
            if char == "\"" { quoted.toggle() }
            else if char.isWhitespace && !quoted { if !current.isEmpty { tokens.append(current); current = "" } }
            else { current.append(char) }
        }
        if !current.isEmpty { tokens.append(current) }
        guard !quoted, tokens.count <= 32 else { throw CaptureError.message(L10n.text("请闭合双引号，搜索最多32个条件。")) }
        terms = try tokens.map { token in
            var value = token; let excluded = value.hasPrefix("-")
            if excluded { value.removeFirst() }
            let field: Field
            if value.hasPrefix("#") { field = .tag; value.removeFirst() }
            else if value.hasPrefix("tag:") { field = .tag; value = String(value.dropFirst(4)) }
            else if value.hasPrefix("collection:") { field = .collection; value = String(value.dropFirst(11)) }
            else if value.hasPrefix("is:") {
                guard value == "is:favorite" else { throw CaptureError.message(L10n.text("is:目前仅支持favorite。")) }
                field = .favorite; value = "favorite"
            } else if value.hasPrefix("type:") {
                field = .type; value = String(value.dropFirst(5))
                guard ["image", "video"].contains(value) else { throw CaptureError.message(L10n.text("type:支持image或video。")) }
            } else { field = .text }
            guard !value.isEmpty else { throw CaptureError.message(L10n.text("搜索条件不能为空。")) }
            return Term(field: field, value: value, excluded: excluded)
        }
    }
    func matches(title: String, text: String, type: String, metadata: MediaMetadata, collections: [MediaCollection]) -> Bool {
        func contains(_ source: String, _ value: String) -> Bool { source.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return terms.allSatisfy { term in
            let found: Bool
            switch term.field {
            case .text: found = contains(title, term.value) || contains(metadata.title, term.value) || contains(text, term.value) || metadata.tags.contains { contains($0, term.value) }
            case .tag: found = metadata.tags.contains { $0.compare(term.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            case .collection: found = collections.contains { metadata.collections.contains($0.id) && $0.name.compare(term.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            case .favorite: found = metadata.favorite
            case .type: found = type == term.value
            }
            return term.excluded ? !found : found
        }
    }
    static func captures(_ records: [CaptureRecord], query: String, metadata: MediaMetadataSnapshot) throws -> Set<UUID> {
        let filter = try Self(query)
        var result = Set<UUID>()
        for record in records {
            try Task.checkCancellation()
            if filter.matches(title: record.title, text: record.recognizedText ?? "", type: "image", metadata: metadata.entries[MediaMetadataKey.capture(record.id)] ?? .init(), collections: metadata.collections) { result.insert(record.id) }
        }
        return result
    }
    static func recordings(_ entries: [RecordingLibraryEntry], query: String, metadata: MediaMetadataSnapshot) throws -> Set<URL> {
        let filter = try Self(query)
        var result = Set<URL>()
        for entry in entries {
            try Task.checkCancellation()
            var transcript = ""
            if filter.terms.contains(where: { $0.field == .text }), let video = entry.video {
                let file = VideoTranscript.url(for: video)
                if RecordingEditStore.exists(video) {
                    let snapshot = try RecordingEditStore.load(video)
                    transcript = snapshot?.captions.filter(\.keep).map(\.text).joined(separator: "\n") ?? ""
                } else if FileManager.default.fileExists(atPath: file.path) {
                    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2_000_000 else { throw CaptureError.message(L10n.text("字幕索引超过2MB，未完成本次搜索。")) }
                    let captions = try JSONDecoder().decode([CaptionSegment].self, from: Data(contentsOf: file))
                    transcript = captions.filter(\.keep).map(\.text).joined(separator: "\n")
                }
            }
            if filter.matches(title: entry.video?.lastPathComponent ?? entry.id.lastPathComponent, text: transcript, type: "video", metadata: metadata.entries[MediaMetadataKey.recording(entry.id)] ?? .init(), collections: metadata.collections) { result.insert(entry.id) }
        }
        return result
    }
}
