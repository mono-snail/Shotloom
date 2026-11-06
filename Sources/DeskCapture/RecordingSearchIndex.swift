import Foundation
import Darwin

/// Actor-owned transcript snapshots. Every query checks file identities; unchanged
/// sidecars are not decoded again. No video pixels or user's clipboard are read.
actor RecordingSearchIndex {
    private struct Stamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init?(_ file: URL) throws {
            var value = stat()
            guard lstat(file.path, &value) == 0 else {
                if errno == ENOENT { return nil }
                throw CaptureError.message(L10n.text("无法读取字幕文件状态，搜索未完成。"))
            }
            guard value.st_mode & S_IFMT == S_IFREG, value.st_size <= 16_000_000 else {
                throw CaptureError.message(L10n.text("字幕文件类型或大小无效，搜索未完成。"))
            }
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    private struct Source: Equatable {
        let video: URL?
        let canonical: Stamp?, legacy: Stamp?
        init(_ video: URL?) throws {
            self.video = video
            canonical = try video.flatMap { try Stamp(RecordingEditStore.url(for: $0)) }
            // Canonical captions take precedence; stale legacy files are irrelevant.
            legacy = canonical == nil ? try video.flatMap { try Stamp(VideoTranscript.url(for: $0)) } : nil
        }
    }
    private struct Cached {
        let id: UUID, source: Source, text: String
    }
    private var cache: [URL: Cached] = [:]
    private var revision = UUID()
    private var decodes = 0
    private let index: CaptureSearchIndex
    init(postingBudget: Int = 2_000_000) { index = CaptureSearchIndex(postingBudget: postingBudget, mediaType: "video") }
    func search(_ entries: [RecordingLibraryEntry], query: String, metadata: MediaMetadataSnapshot) async throws -> Set<URL> {
        _ = try MediaSearchQuery(query)
        guard entries.count <= 20_000, Set(entries.map(\.id)).count == entries.count else { throw CaptureError.message(L10n.text("录屏搜索库超出容量或存在重复条目。")) }
        var next: [URL: Cached] = [:], records: [CaptureRecord] = [], titles: [UUID: String] = [:], ids: [UUID: URL] = [:]
        var translated = metadata; translated.entries = [:]
        var bytes = 0, changed = cache.count != entries.count
        for entry in entries {
            try Task.checkCancellation()
            let source = try Source(entry.video), old = cache[entry.id]
            let value: Cached
            if let old, old.source == source { value = old }
            else {
                var text = ""
                if let video = entry.video {
                    let captions: [CaptionSegment]
                    if source.canonical != nil { captions = try RecordingEditStore.load(video)?.captions ?? [] }
                    else if let legacy = source.legacy {
                        guard legacy.size <= 2_000_000 else { throw CaptureError.message(L10n.text("字幕索引超过2MB，未完成本次搜索。")) }
                        captions = try JSONDecoder().decode([CaptionSegment].self, from: Data(contentsOf: VideoTranscript.url(for: video)))
                    } else { captions = [] }
                    text = captions.filter(\.keep).map(\.text).joined(separator: "\n")
                    guard try Source(entry.video) == source else { throw CaptureError.message(L10n.text("字幕正在改变，请重新搜索。")) }
                    if source.canonical != nil || source.legacy != nil { decodes += 1 }
                }
                value = Cached(id: old?.id ?? UUID(), source: source, text: text); changed = true
            }
            bytes += value.text.utf8.count
            guard bytes <= 128_000_000 else { throw CaptureError.message(L10n.text("录屏搜索文本超过128MB预算，未截断搜索结果。")) }
            next[entry.id] = value; ids[value.id] = entry.id
            let title = entry.video?.lastPathComponent ?? entry.id.lastPathComponent
            // Internal IDs adapt the same query semantics and bounded postings to video.
            // The files referenced by these value records are never opened by the index.
            records.append(CaptureRecord(id: value.id, createdAt: entry.date, filename: "", width: 0, height: 0,
                                         mode: CaptureMode.region.rawValue, recognizedText: value.text))
            titles[value.id] = title
            translated.entries[MediaMetadataKey.capture(value.id)] = metadata.entries[MediaMetadataKey.recording(entry.id)] ?? .init()
            if old == nil || titles[value.id] != cachedTitles[value.id] { changed = true }
        }
        try Task.checkCancellation()
        if changed { revision = UUID() }
        cache = next; cachedTitles = titles
        let currentRevision = revision
        let matches = try await index.search(records, query: query, metadata: translated, version: currentRevision, titles: titles)
        try Task.checkCancellation()
        return Set(matches.compactMap { ids[$0] })
    }
    private var cachedTitles: [UUID: String] = [:]
    func statistics() async -> (index: CaptureSearchStatistics, transcriptDecodes: Int) { (await index.statistics(), decodes) }
}
