import XCTest
@testable import DeskCapture

final class TranscriptEditingTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-transcript-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private var captions: [CaptionSegment] { [.init(start: 0, end: 1, text: "你好 DeskCapture"), .init(start: 2, end: 3, text: "Café hello")] }
    func testSentenceOrderingSpeedAndRepeatedTextUseLinkedCaptionIdentity() throws {
        let original = captions
        var copy = original[0]; copy.id = UUID(); copy.text = "校对后的重复句"
        let reordered = [original[1], original[0], copy]
        let sections = try TranscriptEditing.sentenceSections(reordered, duration: 4, speed: 2)
        let plan = try VideoEditPlan(duration: 4, start: 0, end: 4, captions: reordered, sections: sections)
        XCTAssertEqual(plan.duration, 1.5); XCTAssertEqual(plan.mapAll(0.5), [0.75, 1.25])
        let mapped = plan.mappedCaptions(reordered)
        XCTAssertEqual(mapped.map(\.text), reordered.map(\.text)); XCTAssertEqual(mapped.map(\.start), [0, 0.5, 1])
        var removedOriginal = reordered; removedOriginal[1].keep = false
        let reduced = try VideoEditPlan(duration: 4, start: 0, end: 4, captions: removedOriginal, sections: sections)
        XCTAssertEqual(reduced.mappedCaptions(removedOriginal).map(\.text), [original[1].text, copy.text])
        XCTAssertThrowsError(try TranscriptEditing.sentenceSections([], duration: 4, speed: 1))
    }
    func testFindReplaceUnicodeAndExpansionBudgetPreserveInput() throws {
        let original = captions
        XCTAssertEqual(try TranscriptEditing.matching(original, query: "cafe"), [original[1].id])
        let result = try TranscriptEditing.replacing(original, query: "DESKCAPTURE", replacement: "本机")
        XCTAssertEqual(result[0].text, "你好 本机"); XCTAssertEqual(original[0].text, "你好 DeskCapture")
        XCTAssertThrowsError(try TranscriptEditing.replacing([.init(start: 0, end: 1, text: "aaa")], query: "a", replacement: String(repeating: "界", count: 20_000)))
    }
    func testCanonicalCommitAndFailureKeepCaptionsAndStudioTogether() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mp4"), rows = captions
        try VideoTranscript.save(rows, for: video)
        try RecordingStudioProject().save(video)
        let oldCaptions = try Data(contentsOf: VideoTranscript.url(for: video)), oldStudio = try Data(contentsOf: RecordingStudioProject.url(for: video))
        var effects = RecordingEffectsOptions(); effects.edit = .init(sections: try TranscriptEditing.sentenceSections(rows, duration: 4, speed: 2))
        let snapshot = RecordingEditSnapshot(captions: rows, studio: .init(effects: effects)), initial = try RecordingEditStore.fingerprint(video)
        let committed = try RecordingEditStore.save(snapshot, for: video, expected: initial)
        XCTAssertEqual(VideoTranscript.load(video), rows)
        XCTAssertEqual(RecordingStudioProject.load(video).effects?.edit?.sections.count, 2)
        XCTAssertEqual(try Data(contentsOf: VideoTranscript.url(for: video)), oldCaptions)
        XCTAssertEqual(try Data(contentsOf: RecordingStudioProject.url(for: video)), oldStudio)
        let before = try Data(contentsOf: RecordingEditStore.url(for: video))
        enum Fault: Error { case injected }
        var next = snapshot; next.captions[0].text = "new"; next.studio.effects?.edit?.sections.reverse()
        XCTAssertThrowsError(try RecordingEditStore.save(next, for: video, expected: committed, beforeCommit: { throw Fault.injected }))
        XCTAssertEqual(try Data(contentsOf: RecordingEditStore.url(for: video)), before)
        XCTAssertEqual(try RecordingEditStore.load(video)?.captions[0].text, rows[0].text)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".DeskCapture-editing-") })
    }
    func testOptimisticConflictAndCancelledPrecommitPreserveCurrentSnapshot() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mp4"), snapshot = RecordingEditSnapshot(captions: captions, studio: .init())
        let stale = try RecordingEditStore.fingerprint(video)
        let current = try RecordingEditStore.save(snapshot, for: video, expected: stale)
        XCTAssertThrowsError(try RecordingEditStore.save(snapshot, for: video, expected: stale))
        let before = try Data(contentsOf: RecordingEditStore.url(for: video))
        let worker = Task.detached {
            try RecordingEditStore.save(snapshot, for: video, expected: current, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await worker.value; XCTFail("Must cancel before commit") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(try Data(contentsOf: RecordingEditStore.url(for: video)), before)
    }
    func testLegacyHelpersUpdateCanonicalWithoutDiscardingOtherHalfAndRejectCorruption() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mp4"), rows = captions
        _ = try RecordingEditStore.save(.init(captions: rows, studio: .init()), for: video, expected: try RecordingEditStore.fingerprint(video))
        var changed = rows; changed[0].text = "校对"
        try VideoTranscript.save(changed, for: video)
        var studio = RecordingStudioProject.load(video); studio.lenses = [.init(start: 0, end: 1)]
        try studio.save(video)
        XCTAssertEqual(try RecordingEditStore.load(video)?.captions, changed)
        XCTAssertEqual(try RecordingEditStore.load(video)?.studio.lenses.count, 1)
        try Data("bad JSON".utf8).write(to: RecordingEditStore.url(for: video))
        XCTAssertThrowsError(try RecordingEditStore.load(video))
        XCTAssertThrowsError(try VideoTranscript.save(rows, for: video))
        XCTAssertEqual(try Data(contentsOf: RecordingEditStore.url(for: video)), Data("bad JSON".utf8))
    }
}
