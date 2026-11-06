import XCTest
@testable import DeskCapture

final class RecordingCursorTests: XCTestCase {
    private var events: [RecordedInteraction] { [
        .init(time: 0, x: 0.1, y: 0.2, kind: .pointer),
        .init(time: 0.2, x: 0.1, y: 0.2, kind: .pointer),
        .init(time: 3, x: 0.1, y: 0.2, kind: .click),
        .init(time: 4, x: 0.9, y: 0.8, kind: .pointer)] }
    func testIdleIgnoresUnmovedSamplesAndClickRestoresVisibility() {
        let timeline = RecordingCursorTimeline(events: events)
        var options = RecordingCursorOptions(); options.hideWhenIdle = true; options.idleSeconds = 1
        XCTAssertNotNil(timeline.point(at: 0.5, options: options))
        XCTAssertNil(timeline.point(at: 1.1, options: options))
        XCTAssertNotNil(timeline.point(at: 3, options: options))
        XCTAssertNil(timeline.point(at: -.infinity, options: options))
    }
    func testHiddenPrecedesAuthoredMotionAndSourceEventsStayUnchanged() throws {
        let source = events, timeline = RecordingCursorTimeline(events: source)
        var options = RecordingCursorOptions(); options.hideWhenIdle = true
        options.paths = [.init(start: 1, end: 3, fromX: 0.2, fromY: 0.3, toX: 0.8, toY: 0.7)]
        options.hidden = [.init(start: 1.5, end: 2)]
        try options.validate(duration: 5)
        XCTAssertNil(timeline.point(at: 1.7, options: options))
        XCTAssertEqual(try XCTUnwrap(timeline.point(at: 2, options: options)).x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(source.filter { $0.kind == .click }.map(\.x), [0.1])
        XCTAssertEqual(source.map(\.time), events.map(\.time))
        options.paths.append(.init(start: 2, end: 4))
        XCTAssertThrowsError(try options.validate(duration: 5))
    }
    func testRepeatedAndRetimedEditsUseSameOriginalCursorDecisions() throws {
        let plan = try VideoEditPlan(duration: 5, start: 0, end: 5, captions: [], sections: [
            VideoSection(start: 3, end: 5, speed: 2), VideoSection(start: 0, end: 2), VideoSection(start: 3, end: 5, speed: 0.5)])
        var options = RecordingCursorOptions(); options.hidden = [.init(start: 3, end: 3.5)]
        let timeline = RecordingCursorTimeline(events: events)
        for outputTime in plan.mapAll(3.25) {
            let sourceTime = RecordingEffectsExporter.sourceTime(outputTime, plan: plan)
            XCTAssertEqual(sourceTime, 3.25, accuracy: 0.0001)
            XCTAssertNil(timeline.point(at: sourceTime, options: options))
        }
        XCTAssertEqual(plan.mapAll(3.25).count, 2)
    }
    func testIndependentSourceResolutionAndMissingLegacySourceRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-cursor-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raw.mp4"), result = root.appendingPathComponent("rendered.mp4")
        try Data("raw sentinel".utf8).write(to: source)
        let raw = RecordingInteractions(smoothCursor: true, events: events)
        try JSONEncoder().encode(raw).write(to: RecordingInteractions.url(for: source))
        var processed = RecordingInteractions(smoothCursor: false, events: events); processed.editableCursorSource = "raw.mp4"
        XCTAssertEqual(try EditableCursorSource.resolve(result, metadata: processed), source)
        processed.editableCursorSource = "../raw.mp4"
        XCTAssertThrowsError(try EditableCursorSource.resolve(result, metadata: processed))
        processed.editableCursorSource = nil
        XCTAssertThrowsError(try EditableCursorSource.resolve(result, metadata: processed))
        XCTAssertEqual(try Data(contentsOf: source), Data("raw sentinel".utf8))
        let legacy = Data("{\"version\":1,\"smoothCursor\":false,\"events\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(RecordingInteractions.self, from: legacy).editableCursorSource)
    }
    func testInvalidProjectSavePreservesExistingSidecar() throws {
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-cursor-\(UUID()).mp4")
        let sidecar = RecordingStudioProject.url(for: video), sentinel = Data("existing settings".utf8)
        defer { try? FileManager.default.removeItem(at: sidecar) }
        try sentinel.write(to: sidecar)
        var effects = RecordingEffectsOptions(), options = RecordingCursorOptions()
        options.paths = [.init(start: 0, end: 1, toX: .nan)]; effects.cursor = options
        XCTAssertThrowsError(try RecordingStudioProject(effects: effects).save(video))
        XCTAssertEqual(try Data(contentsOf: sidecar), sentinel)
    }
}
