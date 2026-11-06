import XCTest
@testable import DeskCapture

final class RecordingSearchIndexTests: XCTestCase {
    private func fixture(_ root: URL, _ name: String, _ text: String) throws -> RecordingLibraryEntry {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent(name + ".mp4")
        // File protocol fixture only: no media decoding or playback is claimed.
        try Data("unchanged media fixture".utf8).write(to: video)
        let rows = [CaptionSegment(start: 0, end: 1, text: text), CaptionSegment(start: 1, end: 2, text: "removed secret", keep: false)]
        try JSONEncoder().encode(rows).write(to: VideoTranscript.url(for: video))
        return .init(id: folder, video: video, segments: [], date: .distantPast, bytes: 23)
    }
    func testIndexAndBudgetFallbackMatchReferenceAndReuseUnchangedCaptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try [fixture(root, "café-demo", "中文 tutorial launch"), fixture(root, "other", "reference guide")]
        var metadata = MediaMetadataSnapshot()
        let collection = MediaCollection(name: "教程"); metadata.collections = [collection]
        metadata.entries[MediaMetadataKey.recording(entries[0].id)] = .init(title: "发布说明", tags: ["教程"], favorite: true, collections: [collection.id])
        for index in [RecordingSearchIndex(), RecordingSearchIndex(postingBudget: 0)] {
            for query in ["cafe", "中文", "\"tutorial launch\"", "-removed", "removed", "#教程", "collection:教程 is:favorite", "type:video", "type:image", "guide -中文"] {
                let expected = try MediaSearchQuery.recordings(entries, query: query, metadata: metadata)
                let found = try await index.search(entries, query: query, metadata: metadata)
                XCTAssertEqual(found, expected, query)
            }
            let statistics = await index.statistics()
            XCTAssertEqual(statistics.transcriptDecodes, 2, "Hot queries must not decode unchanged sidecars")
            XCTAssertEqual(statistics.index.documents, 2)
        }
        let bytes = try Data(contentsOf: XCTUnwrap(entries.first?.video))
        XCTAssertEqual(bytes, Data("unchanged media fixture".utf8))
    }
    func testAtomicSidecarReplacementRemovalAndMetadataRevisionInvalidateSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try fixture(root, "demo", "before"), index = RecordingSearchIndex()
        var metadata = MediaMetadataSnapshot()
        let first = try await index.search([entry], query: "before", metadata: metadata)
        XCTAssertEqual(first, [entry.id])
        let captions = VideoTranscript.url(for: try XCTUnwrap(entry.video))
        try JSONEncoder().encode([CaptionSegment(start: 0, end: 1, text: "after!")]).write(to: captions, options: .atomic)
        let stale = try await index.search([entry], query: "before", metadata: metadata)
        let fresh = try await index.search([entry], query: "after!", metadata: metadata)
        XCTAssertTrue(stale.isEmpty); XCTAssertEqual(fresh, [entry.id])
        metadata.sequence += 1; metadata.entries[MediaMetadataKey.recording(entry.id)] = .init(tags: ["new"])
        let classified = try await index.search([entry], query: "#new", metadata: metadata)
        XCTAssertEqual(classified, [entry.id])
        try FileManager.default.removeItem(at: captions)
        let removedText = try await index.search([entry], query: "after!", metadata: metadata)
        XCTAssertTrue(removedText.isEmpty)
        let removedRecord = try await index.search([], query: "#new", metadata: metadata)
        XCTAssertTrue(removedRecord.isEmpty)
    }
    func testCanonicalEditsSupersedeLegacyTextAndInvalidateAfterSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try fixture(root, "canonical", "legacy"), video = try XCTUnwrap(entry.video)
        let index = RecordingSearchIndex()
        _ = try await index.search([entry], query: "legacy", metadata: .init())
        var edit = RecordingEditSnapshot(captions: [.init(start: 0, end: 1, text: "corrected")], studio: .init())
        _ = try RecordingEditStore.save(edit, for: video, expected: nil)
        let corrected = try await index.search([entry], query: "corrected", metadata: .init())
        let legacy = try await index.search([entry], query: "legacy", metadata: .init())
        XCTAssertEqual(corrected, [entry.id]); XCTAssertTrue(legacy.isEmpty)
        edit.captions[0].keep = false
        _ = try RecordingEditStore.save(edit, for: video, expected: nil)
        let removed = try await index.search([entry], query: "corrected", metadata: .init())
        XCTAssertTrue(removed.isEmpty)
    }
    func testInvalidSidecarRefusesWholeQueryInsteadOfReturningPartialResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try [fixture(root, "valid", "target"), fixture(root, "invalid", "target")]
        let file = VideoTranscript.url(for: try XCTUnwrap(entries.last?.video))
        try Data("broken JSON".utf8).write(to: file)
        do { _ = try await RecordingSearchIndex().search(entries, query: "target", metadata: .init()); XCTFail("Partial query was accepted") } catch { }
    }
}
