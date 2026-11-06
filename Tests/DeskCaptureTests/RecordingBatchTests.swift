import XCTest
@testable import DeskCapture

final class RecordingBatchTests: XCTestCase {
    func testCorruptHistoryRecoveryDoesNotAbsorbUnindexedExports() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let image = WorkflowCorpus.texture(width: 24, height: 18, seed: 8)
        let store = CaptureStore(directory: root, pruneOnInit: false)
        let record = try store.add(image, mode: .region)
        let export = root.appendingPathComponent("user-export.png")
        try CaptureImageExport.png(image, to: export)
        let bytes = try Data(contentsOf: export)
        try Data("bad index".utf8).write(to: root.appendingPathComponent("history.json"))
        let recovered = CaptureStore(directory: root, pruneOnInit: false)
        XCTAssertEqual(recovered.records.map(\.id), [record.id])
        XCTAssertEqual(try Data(contentsOf: export), bytes)
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-recording-batch-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private func seed(_ root: URL) throws -> [RecordingLibraryEntry] {
        try (0..<2).map { index in
            let folder = root.appendingPathComponent("session-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for name in ["DeskCapture-final.mp4", "segment-1.mp4", "camera.mp4", "DeskCapture-final.captions.json"] {
                // Opaque bytes exercise file transactions, not media decoding.
                try Data("\(index):\(name)".utf8).write(to: folder.appendingPathComponent(name))
            }
            return RecordingLibraryEntry(id: folder, video: folder.appendingPathComponent("DeskCapture-final.mp4"), segments: [folder.appendingPathComponent("segment-1.mp4")], date: Date(), bytes: 1)
        }
    }
    func testRemoveAndRestorePreserveAllSessionArtifactsAndOutsideScope() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try seed(root), outside = try Data(contentsOf: entries[1].video!)
        let archive = try RecordingBatchTransactions.remove([entries[0]], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entries[0].id.path))
        XCTAssertEqual(try Data(contentsOf: entries[1].video!), outside)
        XCTAssertEqual(try RecordingBatchTransactions.archives(root).first?.id, archive.id)
        try RecordingBatchTransactions.restore(archive, root: root)
        for name in ["DeskCapture-final.mp4", "segment-1.mp4", "camera.mp4", "DeskCapture-final.captions.json"] {
            XCTAssertEqual(try Data(contentsOf: entries[0].id.appendingPathComponent(name)), Data("0:\(name)".utf8))
        }
        XCTAssertTrue(try RecordingBatchTransactions.archives(root).isEmpty)
    }
    func testFailureAndActualCancellationRollbackWholeBatch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try seed(root)
        XCTAssertThrowsError(try RecordingBatchTransactions.remove(entries, root: root, beforeCommit: { throw CaptureError.message("Injected failure") }))
        for entry in entries { XCTAssertTrue(FileManager.default.fileExists(atPath: entry.video!.path)) }
        let worker = Task.detached {
            try RecordingBatchTransactions.remove(entries, root: root, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await worker.value; XCTFail("Cancelled batch committed") } catch { XCTAssertTrue(error is CancellationError) }
        for entry in entries { XCTAssertTrue(FileManager.default.fileExists(atPath: entry.video!.path)) }
        XCTAssertTrue(try RecordingBatchTransactions.archives(root).isEmpty)
    }
    func testRestoreConflictPreservesBothCurrentAndArchivedDirectories() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try seed(root), archive = try RecordingBatchTransactions.remove([entries[0]], root: root)
        try FileManager.default.createDirectory(at: entries[0].id, withIntermediateDirectories: false)
        let sentinel = entries[0].id.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try RecordingBatchTransactions.restore(archive, root: root))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try RecordingBatchTransactions.archives(root).count, 1)
    }
    func testPreparedJournalRecoveryRollsBackAndIsIdempotent() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try seed(root), id = UUID(), relative = ".recordings-archive/\(id)"
        let folder = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = RecordingArchive(id: id, createdAt: Date(), folders: entries.map { $0.id.lastPathComponent })
        try JSONEncoder().encode(archive).write(to: folder.appendingPathComponent("archive.json"))
        try FileManager.default.moveItem(at: entries[0].id, to: folder.appendingPathComponent(entries[0].id.lastPathComponent))
        let moves = entries.map { ["from": $0.id.lastPathComponent, "to": relative + "/" + $0.id.lastPathComponent] }
        let journal: [String: Any] = ["committed": false, "moves": moves, "cleanupOnRollback": relative]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent(".recordings-transaction.json"))
        XCTAssertEqual(try RecordingLibrary.checkedEntries(directory: root).count, 2)
        XCTAssertEqual(try RecordingLibrary.checkedEntries(directory: root).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    func testDefaultExportCopiesOnlyFinalAndFailureLeavesNoPartialBatch() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try seed(root), output = root.appendingPathComponent("export")
        XCTAssertThrowsError(try RecordingBatchExporter.export(entries, root: root, includeSources: true, to: output, beforeCommit: { throw CancellationError() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try RecordingBatchExporter.export(entries, root: root, includeSources: false, to: output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), ["recording-0001.mp4", "recording-0002.mp4"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("recording-0001.mp4")), try Data(contentsOf: entries[0].video!))
    }
    @MainActor func testAsyncClearKeepsExportsAndUsesIsolatedPreferences() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "DeskCapture.history.clear.tests.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let store = CaptureStore(directory: root, pruneOnInit: false, preferences: isolated)
        _ = try await store.addAsync(WorkflowCorpus.texture(width: 24, height: 18, seed: 11), mode: .region)
        let exported = root.appendingPathComponent("export.png"); try Data("keep".utf8).write(to: exported)
        try await store.clearAllAsync()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: exported), Data("keep".utf8))
    }
}
