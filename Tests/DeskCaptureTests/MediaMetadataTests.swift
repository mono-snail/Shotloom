import XCTest
@testable import DeskCapture

final class MediaMetadataTests: XCTestCase {
    func testBatchClassificationIsAllOrNothingAndDoesNotTouchOutsideScope() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = MediaMetadataRepository(directory: root)
        let keys = (0..<3).map { _ in MediaMetadataKey.capture(UUID()) }
        let original = MediaMetadata(tags: ["old"])
        for key in keys { _ = try await repository.save(key: key, value: original, expected: .init()) }
        let file = root.appendingPathComponent("metadata.json"), before = try Data(contentsOf: file)
        let change = MediaBatchClassification(addTags: ["new"], removeTags: ["old"], favorite: true)
        do {
            _ = try await repository.classifyBatch(Set(keys.prefix(2)), change: change, expected: [keys[0]: original, keys[1]: .init(title: "stale")])
            XCTFail("Stale batch committed")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), before)
        let state = try await repository.classifyBatch(Set(keys.prefix(2)), change: change, expected: [keys[0]: original, keys[1]: original])
        XCTAssertEqual(state.entries[keys[0]]?.tags, ["new"])
        XCTAssertEqual(state.entries[keys[1]]?.favorite, true)
        XCTAssertEqual(state.entries[keys[2]], original)
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-metadata-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    func testCollectionsUnifyImageAndVideoWithoutChangingFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.png"), project = root.appendingPathComponent("source.deskcap"), video = root.appendingPathComponent("movie.mp4")
        for file in [original, project, video] { try Data(file.lastPathComponent.utf8).write(to: file) }
        let repository = MediaMetadataRepository(directory: root.appendingPathComponent("metadata"))
        let first = try await repository.snapshot(); XCTAssertTrue(first.entries.isEmpty)
        let created = try await repository.addCollection("教程")
        let id = try XCTUnwrap(created.collections.first?.id)
        let value = MediaMetadata(title: "示例", tags: ["教程", "macOS"], favorite: true, collections: [id])
        let captureKey = MediaMetadataKey.capture(UUID()), videoKey = MediaMetadataKey.recording(root.appendingPathComponent("recording-01"))
        _ = try await repository.save(key: captureKey, value: value, expected: .init())
        let both = try await repository.save(key: videoKey, value: value, expected: .init())
        XCTAssertEqual(both.entries[captureKey]?.collections, both.entries[videoKey]?.collections)
        let removed = try await repository.removeCollection(id)
        XCTAssertTrue(try XCTUnwrap(removed.entries[captureKey]).collections.isEmpty)
        XCTAssertTrue(try XCTUnwrap(removed.entries[videoKey]).collections.isEmpty)
        for file in [original, project, video] { XCTAssertEqual(try Data(contentsOf: file), Data(file.lastPathComponent.utf8)) }
    }
    func testIndependentRepositoriesReadFreshStateAndRejectStaleEdits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = MediaMetadataRepository(directory: root), b = MediaMetadataRepository(directory: root)
        let x = MediaMetadataKey.capture(UUID()), y = MediaMetadataKey.capture(UUID())
        let old = MediaMetadata(), one = MediaMetadata(title: "one"), two = MediaMetadata(title: "two")
        _ = try await a.save(key: x, value: one, expected: old)
        _ = try await b.save(key: y, value: two, expected: old)
        do { _ = try await b.save(key: x, value: two, expected: old); XCTFail("Stale edit accepted") } catch { }
        let saved = try await a.snapshot()
        XCTAssertEqual(saved.entries[x]?.title, "one"); XCTAssertEqual(saved.entries[y]?.title, "two")
        _ = try await a.toggleFavorite(x)
        let toggledTwice = try await a.toggleFavorite(x)
        XCTAssertEqual(toggledTwice.entries[x]?.favorite, false)
    }
    func testWriteFailureAndCancellationPreserveCommittedIndex() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = MediaMetadataKey.capture(UUID()), original = MediaMetadata(title: "keep")
        let repository = MediaMetadataRepository(directory: root)
        _ = try await repository.save(key: key, value: original, expected: .init())
        let file = root.appendingPathComponent("metadata.json"), bytes = try Data(contentsOf: file)
        let failure = MediaMetadataRepository(directory: root, beforeCommit: { throw CaptureError.message("Injected disk failure") })
        do { _ = try await failure.save(key: key, value: .init(title: "lost"), expected: original); XCTFail("Failure ignored") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let cancelled = MediaMetadataRepository(directory: root, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let worker = Task { try await cancelled.save(key: key, value: .init(title: "cancelled"), expected: original) }
        do { _ = try await worker.value; XCTFail("Cancelled save committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testMalformedOldIndexIsPreservedInsteadOfBeingReset() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.json"), bytes = Data("broken index".utf8)
        try bytes.write(to: file)
        let repository = MediaMetadataRepository(directory: root)
        do { _ = try await repository.save(key: MediaMetadataKey.capture(UUID()), value: .init(title: "new"), expected: .init()); XCTFail("Corrupt index overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertThrowsError(try MediaMetadata(tags: ["tag", " TAG "]).validated())
        XCTAssertFalse(MediaMetadataKey.valid("recording:../escape"))
    }
    func testCombinationSearchCoversOCRTagsCollectionsAndExclusions() throws {
        let id = UUID(), collection = MediaCollection(name: "教程 集合")
        let metadata = MediaMetadata(title: "自定义", tags: ["设计", "macOS"], favorite: true, collections: [collection.id])
        let query = try MediaSearchQuery("\"截图 示例\" #设计 collection:\"教程 集合\" is:favorite type:image -排除")
        XCTAssertTrue(query.matches(title: "原名", text: "这里是截图 示例文字", type: "image", metadata: metadata, collections: [collection]))
        XCTAssertFalse(query.matches(title: "原名", text: "截图 示例 排除", type: "image", metadata: metadata, collections: [collection]))
        XCTAssertFalse(query.matches(title: "原名", text: "截图 示例", type: "video", metadata: metadata, collections: [collection]))
        XCTAssertThrowsError(try MediaSearchQuery("\"unfinished")); XCTAssertThrowsError(try MediaSearchQuery("is:unknown"))
        var snapshot = MediaMetadataSnapshot(); snapshot.collections = [collection]; snapshot.entries[MediaMetadataKey.capture(id)] = metadata
        let record = CaptureRecord(id: id, createdAt: Date(), filename: "kept.png", width: 20, height: 20, mode: "region", recognizedText: "截图 示例")
        XCTAssertEqual(try MediaSearchQuery.captures([record], query: "#设计 is:favorite", metadata: snapshot), [id])
    }
    func testRecordingSearchIncludesSavedCaptions() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        try VideoTranscript.save([.init(start: 0, end: 1, text: "字幕里的检索词")], for: video)
        let entry = RecordingLibraryEntry(id: root, video: video, segments: [], date: Date(), bytes: 0)
        XCTAssertEqual(try MediaSearchQuery.recordings([entry], query: "检索词 type:video", metadata: .init()), [root])
        let index = VideoTranscript.url(for: video)
        try Data("bad captions".utf8).write(to: index)
        XCTAssertThrowsError(try MediaSearchQuery.recordings([entry], query: "检索词", metadata: .init()))
        // Metadata-only searches do not read an unrelated damaged caption file.
        XCTAssertEqual(try MediaSearchQuery.recordings([entry], query: "type:video", metadata: .init()), [root])
    }
}
