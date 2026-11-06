import XCTest
@testable import DeskCapture

final class LocalSpeechTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-local-speech-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    func testMillisecondsChineseEnglishAndDurationBounds() throws {
        let data = Data(#"{"transcription":[{"offsets":{"from":100,"to":1250},"text":"  你好 DeskCapture  "},{"offsets":{"from":1400,"to":3000},"text":"Hello 世界"}]}"#.utf8)
        let rows = try LocalSpeechTranscriber.parse(data, duration: 2)
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows[0].start, 0.1); XCTAssertEqual(rows[0].end, 1.25)
        XCTAssertEqual(rows[0].text, "你好 DeskCapture"); XCTAssertEqual(rows[1].end, 2)
        let malformed = Data(#"{"transcription":[{"offsets":{"from":2000,"to":1000},"text":"invalid"}]}"#.utf8)
        XCTAssertThrowsError(try LocalSpeechTranscriber.parse(malformed, duration: 3))
        XCTAssertThrowsError(try LocalSpeechTranscriber.parse(Data("{}".utf8), duration: 1))
    }
    func testInvalidModelImportPreservesExistingModelAndSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalSpeechModels(root: root), invalid = root.appendingPathComponent("invalid.bin")
        let existing = await library.url(.tiny), sentinel = Data("existing model".utf8)
        try sentinel.write(to: existing); try Data("wrong model".utf8).write(to: invalid)
        do { try await library.importFile(invalid, tier: .tiny); XCTFail("Must reject wrong size/hash") } catch {}
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: invalid), Data("wrong model".utf8))
        let installed = await library.installed(); XCTAssertFalse(installed.contains(.tiny))
    }
    func testProcessTimeoutAndCancellationReapOwnedChild() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sleeper = URL(fileURLWithPath: "/bin/sleep")
        let timed = Task.detached { try LocalSpeechTranscriber.execute(sleeper, arguments: ["30"], directory: root, timeout: 0.15) }
        do { try await timed.value; XCTFail("Must time out") } catch {}
        let cancelled = Task.detached { try LocalSpeechTranscriber.execute(sleeper, arguments: ["30"], directory: root) }
        try await Task.sleep(for: .milliseconds(150)); cancelled.cancel()
        do { try await cancelled.value; XCTFail("Must cancel") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        // execute waits for its own child to exit before returning; isolated directory can now be removed.
    }
    func testCatalogHashesAndImportOfExplicitRealFixtureWhenProvided() async throws {
        for tier in LocalSpeechTier.allCases { XCTAssertEqual(tier.sha256.count, 64); XCTAssertGreaterThan(tier.bytes, 1_000_000) }
        guard let path = ProcessInfo.processInfo.environment["DESKCAPTURE_SPEECH_TINY_FIXTURE"] else { throw XCTSkip("Real weight fixture not configured; no inference/model-load claim") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalSpeechModels(root: root)
        try await library.importFile(URL(fileURLWithPath: path), tier: .tiny)
        let installed = await library.installed(); XCTAssertTrue(installed.contains(.tiny))
        _ = try await library.acquire(.tiny)
        do { try await library.remove(.tiny); XCTFail("Must preserve in-use model") } catch {}
        await library.release(.tiny); try await library.remove(.tiny)
        let remaining = await library.installed(); XCTAssertTrue(remaining.isEmpty)
    }
}
