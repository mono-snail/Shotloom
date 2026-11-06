import XCTest
import CryptoKit
@testable import DeskCapture

final class HistoryBatchTests: XCTestCase {
    @MainActor func testConcurrentAsyncAddsAndRestoreDoNotLoseIndexEntries() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(directory: root)
        let image = WorkflowCorpus.texture(width: 24, height: 18, seed: 7)
        let first = try await store.addAsync(image, mode: .region)
        let archive = try await store.removeBatch([first.id])
        async let addition = store.addAsync(image, mode: .region)
        async let restoration: Void = store.restoreBatch(archive.id)
        let added = try await addition
        try await restoration
        XCTAssertEqual(Set(store.records.map(\.id)), [first.id, added.id])
        XCTAssertEqual(Set(try HistoryTransactions.load(root).map(\.id)), [first.id, added.id])
    }
    func testUnpublishedRemovalManifestDoesNotBecomeFalseRecoveryBatch() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root), archive = HistoryArchive(id: UUID(), createdAt: Date(), records: rows)
        let folder = root.appendingPathComponent(".history-archive/\(archive.id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: folder.appendingPathComponent("archive.json"))
        XCTAssertTrue(try HistoryTransactions.archives(root).isEmpty)
        for record in rows { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.filename).path)) }
    }
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-batch-history-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); return root
    }
    private func seed(_ root: URL) throws -> [CaptureRecord] {
        let records = (0..<2).map { n in CaptureRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: Double(n)), filename: "capture-\(n).png", width: 32, height: 24, mode: "region", recognizedText: "private OCR \(n)", projectFilename: "capture-\(n).deskcap") }
        for (n, record) in records.enumerated() {
            let image = WorkflowCorpus.texture(width: 32, height: 24, seed: UInt64(n + 1))
            try CaptureImageExport.png(image, to: root.appendingPathComponent(record.filename))
            try AnnotationDocument(image: image).projectData().write(to: root.appendingPathComponent(record.projectFilename!))
        }
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("history.json")); return records
    }
    func testRemoveRestoreCommitsHistoryAndProjectsAndLeavesOutsideSelectionUntouched() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root)
        let original = try Data(contentsOf: root.appendingPathComponent(rows[0].filename))
        let project = try Data(contentsOf: root.appendingPathComponent(rows[0].projectFilename!))
        let outside = try Data(contentsOf: root.appendingPathComponent(rows[1].filename))
        let (remaining, archive) = try HistoryTransactions.remove([rows[0].id], directory: root)
        XCTAssertEqual(remaining.map(\.id), [rows[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(rows[0].filename).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(rows[1].filename)), outside)
        XCTAssertEqual(try HistoryTransactions.archives(root).first?.id, archive.id)
        let restored = try HistoryTransactions.restore(archive.id, directory: root)
        XCTAssertEqual(Set(restored.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(rows[0].filename)), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(rows[0].projectFilename!)), project)
        XCTAssertEqual(restored.first(where: { $0.id == rows[0].id })?.recognizedText, rows[0].recognizedText)
        XCTAssertTrue(try HistoryTransactions.archives(root).isEmpty)
    }
    func testFailureBeforeIndexRollsAllMovedFilesBack() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root), originalIndex = try Data(contentsOf: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try HistoryTransactions.remove(Set(rows.map(\.id)), directory: root, beforeIndex: { throw CaptureError.message("Injected write failure") }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), originalIndex)
        for record in rows { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.filename).path)); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.projectFilename!).path)) }
        XCTAssertTrue(try HistoryTransactions.archives(root).isEmpty)
    }
    func testActualCancellationBeforeIndexRestoresEntireBatch() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root), original = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let worker = Task.detached {
            try HistoryTransactions.remove(Set(rows.map(\.id)), directory: root, beforeIndex: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await worker.value; XCTFail("Cancelled removal committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), original)
        XCTAssertEqual(Set(try HistoryTransactions.load(root).map(\.id)), Set(rows.map(\.id)))
    }
    func testRecoveryOfPreparedJournalIsIdempotent() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root), old = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let id = UUID(), folder = ".history-archive/\(id)"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        let moved = rows[0].filename
        try FileManager.default.moveItem(at: root.appendingPathComponent(moved), to: root.appendingPathComponent(folder + "/" + moved))
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let journal: [String: Any] = ["id": id.uuidString, "before": hash(old), "after": String(repeating: "0", count: 64),
            "moves": [["from": moved, "to": folder + "/" + moved]], "cleanupOnCommit": [], "cleanupOnRollback": [folder]]
        try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent(".history-transaction.json"))
        XCTAssertEqual(try HistoryTransactions.load(root).count, 2)
        XCTAssertEqual(try HistoryTransactions.load(root).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(moved).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path))
    }
    func testExportFailureLeavesNoPartialBatchAndDefaultExcludesProjectsAndOCR() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root), output = root.appendingPathComponent("export")
        XCTAssertThrowsError(try CaptureBatchExporter.export(rows, directory: root, includeProjects: true, to: output, beforeCommit: { throw CancellationError() }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try CaptureBatchExporter.export(rows, directory: root, includeProjects: false, to: output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(), ["capture-0001.png", "capture-0002.png"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("capture-0001.png")), try Data(contentsOf: root.appendingPathComponent(rows[0].filename)))
    }
    func testSharedFileReferenceIsRejectedBeforeAnyMovement() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = try seed(root)
        let duplicate = CaptureRecord(id: UUID(), createdAt: Date(), filename: rows[0].filename, width: 32, height: 24, mode: "region")
        try JSONEncoder().encode(rows + [duplicate]).write(to: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try HistoryTransactions.remove([rows[0].id], directory: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(rows[0].filename).path))
    }
}
