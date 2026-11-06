import XCTest
@testable import DeskCapture

final class RecordingRecoveryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-recovery-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func event(_ time: Double) -> RecordedInteraction { .init(time: time, x: 0.3, y: 0.7, kind: .click) }
    func testCommittedPrefixIgnoresUncommittedTailAndNextCheckpointTruncatesIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await RecordingSessionJournal.create(directory: root, fps: 30, smoothCursor: true)
        let segments = [RecordingSessionSegment(video: "segment-0.mov", sourceStart: 0)]
        try await journal.checkpoint(segments: segments, status: .recording, events: [event(0.25)], drawing: [.init(time: 0.2, marks: [])])
        let first = try XCTUnwrap(RecordingSessionJournal.read(root))
        let file = root.appendingPathComponent("recording-checkpoints.jsonl")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("uncommitted garbage\n".utf8)); try handle.close()
        let recovered = try RecordingSessionJournal.readTimeline(root, manifest: first)
        XCTAssertEqual(recovered.0.events.map(\.time), [0.25]); XCTAssertEqual(recovered.1.frames.map(\.time), [0.2])
        try await journal.checkpoint(segments: segments, status: .paused, events: [event(0.5)], drawing: [])
        let second = try XCTUnwrap(RecordingSessionJournal.read(root))
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(try Data(contentsOf: file).count, Int(second.checkpointBytes))
        XCTAssertEqual(try RecordingSessionJournal.readTimeline(root, manifest: second).0.events.map(\.time), [0.25, 0.5])
    }
    func testTruncatedCommittedLogIsRejectedWithoutMutation() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await RecordingSessionJournal.create(directory: root, fps: 60, smoothCursor: false)
        try await journal.checkpoint(segments: [], status: .recording, events: [event(1)], drawing: [])
        let manifest = try XCTUnwrap(RecordingSessionJournal.read(root)), file = root.appendingPathComponent("recording-checkpoints.jsonl")
        let bytes = try Data(contentsOf: file); try bytes.dropLast().write(to: file)
        let truncated = try Data(contentsOf: file)
        XCTAssertThrowsError(try RecordingSessionJournal.readTimeline(root, manifest: manifest))
        XCTAssertEqual(try Data(contentsOf: file), truncated)
    }
    func testCancelledCheckpointPreservesCommitMarker() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = try await RecordingSessionJournal.create(directory: root, fps: 30, smoothCursor: false)
        let before = try Data(contentsOf: RecordingSessionJournal.url(root))
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await journal.checkpoint(segments: [], status: .paused, events: [], drawing: [])
        }
        do { try await worker.value; XCTFail("Cancelled checkpoint committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: RecordingSessionJournal.url(root)), before)
    }
    func testActiveSessionCannotBeRecoveredArchivedOrBatchExported() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let lease = try RecordingSessionLease(directory: source); defer { withExtendedLifetime(lease) {} }
        try JSONEncoder().encode(RecordingSessionManifest(fps: 30, smoothCursor: false)).write(to: RecordingSessionJournal.url(source))
        XCTAssertFalse(RecordingSessionLease.available(source))
        let entry = RecordingLibraryEntry(id: source, video: nil, segments: [], date: Date(), bytes: 0)
        XCTAssertThrowsError(try RecordingBatchTransactions.remove([entry], root: root))
        let output = root.appendingPathComponent("Export")
        XCTAssertThrowsError(try RecordingBatchExporter.export([entry], root: root, includeSources: true, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testMissingMiddleRangeDropsItsEventsAndCarriesLatestDrawingState() {
        let ranges = [RecordingRecoveredRange(sourceStart: 0, duration: 2, outputStart: 0), .init(sourceStart: 5, duration: 2, outputStart: 2)]
        let mapped = RecordingSessionRecovery.map([event(1), event(2), event(4), event(5), event(6.5), event(7)], ranges: ranges)
        XCTAssertEqual(mapped.map(\.time), [1, 2, 3.5])
        let drawing = RecordingDrawingTimeline(frames: [.init(time: 0.5, marks: []), .init(time: 4, marks: []), .init(time: 6, marks: [])])
        XCTAssertEqual(RecordingSessionRecovery.map(drawing, ranges: ranges).frames.map(\.time), [0.5, 2, 3])
    }
    func testDiskBudgetRejectsShortageAndInvalidBudget() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try RecordingStorageBudget.require(root, bytes: 256_000_000, available: 255_999_999))
        XCTAssertThrowsError(try RecordingStorageBudget.require(root, bytes: -1, available: 500_000_000))
        XCTAssertNoThrow(try RecordingStorageBudget.require(root, bytes: 256_000_000, available: 256_000_000))
    }
    func testDependencyGuardRejectsSameSizeMutationReplacementAndNewSidecar() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.mp4"), sidecar = root.appendingPathComponent("optional.json")
        try Data("AAAA".utf8).write(to: file)
        let first = try ProjectDependencySnapshot([file, sidecar]); try first.verify()
        try Data("BBBB".utf8).write(to: file)
        XCTAssertThrowsError(try first.verify())
        let second = try ProjectDependencySnapshot([file, sidecar])
        try Data("BBBB".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try second.verify())
        let third = try ProjectDependencySnapshot([file, sidecar])
        try Data("{}".utf8).write(to: sidecar)
        XCTAssertThrowsError(try third.verify())
    }
    func testDependencyGuardRejectsSymbolicLinkAndManifestTraversal() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try Data([1]).write(to: target); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ProjectDependencySnapshot([link]))
        var manifest = RecordingSessionManifest(fps: 30, smoothCursor: false)
        manifest.segments = [.init(video: "../elsewhere.mov", sourceStart: 0)]
        XCTAssertThrowsError(try manifest.validate())
        manifest.segments = [.init(video: "segment-0.mov", sourceStart: .nan)]
        XCTAssertThrowsError(try manifest.validate())
    }
}
