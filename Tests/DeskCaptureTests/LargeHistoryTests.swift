import XCTest
import AppKit
@testable import DeskCapture

final class LargeHistoryTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-large-history-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    func testIndexedAndBudgetFallbackMatchReferenceIncludingUnicodeAndExclusion() async throws {
        let records = (0..<120).map { index in CaptureRecord(id: UUID(), createdAt: Date(), filename: "\(index).png", width: 20, height: 20, mode: "region", recognizedText: index % 2 == 0 ? "Café 中文 İstanbul alpha \(index)" : "beta Straße e\u{301} \(index)") }
        let collection = MediaCollection(name: "教程 甲")
        var metadata = MediaMetadataSnapshot(); metadata.collections = [collection]
        for (i, row) in records.enumerated() {
            metadata.entries[MediaMetadataKey.capture(row.id)] = .init(tags: [i % 2 == 0 ? "设计" : "其他"], favorite: i % 3 == 0, collections: i % 4 == 0 ? [collection.id] : [])
        }
        let indexed = CaptureSearchIndex(), fallback = CaptureSearchIndex(postingBudget: 0), version = UUID()
        for query in ["cafe", "中文 #设计", "\"教程 甲\"", "collection:\"教程 甲\" is:favorite", "alpha -#其他", "beta -is:favorite", "type:video", "-type:image", "strasse", "é", "不存在"] {
            let expected = try MediaSearchQuery.captures(records, query: query, metadata: metadata)
            let a = try await indexed.search(records, query: query, metadata: metadata, version: version)
            let b = try await fallback.search(records, query: query, metadata: metadata, version: version)
            XCTAssertEqual(a, expected, query); XCTAssertEqual(b, expected, query)
        }
        let stats = await fallback.statistics(); XCTAssertFalse(stats.indexed); XCTAssertEqual(stats.documents, records.count)
        let accelerated = await indexed.statistics()
        XCTAssertTrue(accelerated.indexed); XCTAssertGreaterThan(accelerated.postings, 0)
    }
    func testRevisionAndClassificationChangesInvalidateCachedIndex() async throws {
        var records = [CaptureRecord(id: UUID(), createdAt: Date(), filename: "one.png", width: 20, height: 20, mode: "region", recognizedText: "oldword")]
        let index = CaptureSearchIndex(), version = UUID()
        var metadata = MediaMetadataSnapshot()
        let old = try await index.search(records, query: "oldword", metadata: metadata, version: version)
        XCTAssertEqual(old, [records[0].id])
        metadata.sequence = 1; metadata.entries[MediaMetadataKey.capture(records[0].id)] = .init(favorite: true)
        let favorite = try await index.search(records, query: "is:favorite", metadata: metadata, version: version)
        XCTAssertEqual(favorite, [records[0].id])
        records[0].recognizedText = "newword"
        let changed = try await index.search(records, query: "oldword", metadata: metadata, version: UUID())
        XCTAssertTrue(changed.isEmpty)
    }
    func testThumbnailCacheReusesEvictsAndNeverTouchesOriginal() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryThumbnailCache(byteBudget: 100_000, itemBudget: 1)
        let a = root.appendingPathComponent("a.png"), b = root.appendingPathComponent("b.png")
        try CaptureImageExport.png(WorkflowCorpus.texture(width: 80, height: 60, seed: 1), to: a)
        try CaptureImageExport.png(WorkflowCorpus.texture(width: 80, height: 60, seed: 2), to: b)
        let original = try Data(contentsOf: a)
        _ = try await cache.image(at: a, edge: 64); _ = try await cache.image(at: a, edge: 64)
        let initial = await cache.statistics()
        XCTAssertEqual(initial.decodes, 1)
        _ = try await cache.image(at: b, edge: 64); _ = try await cache.image(at: a, edge: 64)
        let stats = await cache.statistics()
        XCTAssertEqual(stats.decodes, 3); XCTAssertEqual(stats.items, 1); XCTAssertLessThanOrEqual(stats.pixelBytes, 100_000)
        XCTAssertEqual(try Data(contentsOf: a), original)
    }
    @MainActor func testTenThousandFixtureLoadAndSearchPerformance() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeskCapture.large-history.tests.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let rows = try await Task.detached {
            let rows = (0..<10_000).map { index in CaptureRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: Double(index)), filename: "\(index).png", width: 32, height: 24, mode: "region", recognizedText: String(format: "订单编号 ID-%05d · tutorial alpha · 中文 English", index)) }
        // Index scaling fixture: all references exist, with intentionally repeated
        // pixels via hard links; this does not model ten thousand unique images.
        let seed = root.appendingPathComponent("seed.png")
        try CaptureImageExport.png(WorkflowCorpus.texture(width: 32, height: 24, seed: 9), to: seed)
        for row in rows { try FileManager.default.linkItem(at: seed, to: root.appendingPathComponent(row.filename)) }
        try JSONEncoder().encode(rows).write(to: root.appendingPathComponent("history.json"))
            return rows
        }.value
        let store = CaptureStore(directory: root, pruneOnInit: false, preferences: isolated, deferLoading: true)
        XCTAssertTrue(store.records.isEmpty); XCTAssertTrue(store.isLoading)
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await store.loadInitial()
        let load = ProcessInfo.processInfo.systemUptime - loadStart
        XCTAssertEqual(store.records.count, 10_000); XCTAssertFalse(store.isLoading)
        let index = CaptureSearchIndex(), version = store.contentRevision, metadata = MediaMetadataSnapshot()
        let coldStart = ProcessInfo.processInfo.systemUptime
        let initial = try await index.search(store.records, query: "ID-09999", metadata: metadata, version: version)
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        XCTAssertEqual(initial, [rows[9999].id])
        var times: [Double] = []
        for query in ["ID-00001", "alpha", "中文", "ID-09999 -不存在", "type:image alpha"] {
            let expected = try MediaSearchQuery.captures(rows, query: query, metadata: metadata)
            for _ in 0..<4 {
                let start = ProcessInfo.processInfo.systemUptime
                let actual = try await index.search(store.records, query: query, metadata: metadata, version: version)
                times.append(ProcessInfo.processInfo.systemUptime - start); XCTAssertEqual(actual, expected)
            }
        }
        let sorted = times.sorted(), p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], stats = await index.statistics()
        let report: [String: Any] = ["fixture": "10000-index-records-repeated-pixel-hardlinks", "loadSeconds": load, "coldIndexSeconds": cold,
            "warmSearchP95Seconds": p95, "samples": times, "postingCount": stats.postings, "foldedBytes": stats.foldedBytes, "indexed": stats.indexed]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("R29_PERFORMANCE " + String(decoding: data, as: UTF8.self))
        if let path = ProcessInfo.processInfo.environment["DESKCAPTURE_PERFORMANCE_REPORT_DIR"] {
            let folder = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("r29-\(UUID()).json"), options: .atomic)
        }
        // Declared before measurement, not tuned after seeing the final run.
        XCTAssertLessThan(load, 2); XCTAssertLessThan(cold, 3); XCTAssertLessThan(p95, 0.150)
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
    }
}
