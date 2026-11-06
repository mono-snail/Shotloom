import XCTest
import CryptoKit
@testable import DeskCapture

final class HistoryPermanentCleanupTests: XCTestCase {
    private func seed() throws -> (URL, [CaptureRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-permanent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let rows = (0..<2).map { n in CaptureRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: Double(n)), filename: "sample-\(n).png", width: 2, height: 2, mode: "region", projectFilename: "sample-\(n).deskcap") }
        for row in rows {
            for name in [row.filename, row.projectFilename!] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        }
        try JSONEncoder().encode(rows).write(to: root.appendingPathComponent("history.json"))
        try Data("export must survive".utf8).write(to: root.appendingPathComponent("export.png"))
        return (root, rows)
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    func testRetentionRemovesOnlyExpiredOriginalAndProjectAndToleratesMissingFile() throws {
        let (root, rows) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(rows[0].filename))
        let result = try HistoryTransactions.permanentlyRemove(directory: root, olderThan: Date(timeIntervalSince1970: 0.5))
        XCTAssertEqual(result.records.map(\.id), [rows[1].id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(rows[0].projectFilename!).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(rows[1].filename)), Data(rows[1].filename.utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("export.png")), Data("export must survive".utf8))
        XCTAssertNil(result.warning)
    }
    func testIndexFailureRollsBackOriginalsProjectsAndIndexTogether() throws {
        let (root, rows) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try Data(contentsOf: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try HistoryTransactions.permanentlyRemove(directory: root, beforeIndex: { throw CaptureError.message("injected") }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), old)
        for row in rows {
            for name in [row.filename, row.projectFilename!] { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8)) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".history-transaction.json").path))
    }
    func testCancellationBeforeIndexDoesNotCommitPermanentRemoval() async throws {
        let (root, rows) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = Task.detached {
            try HistoryTransactions.permanentlyRemove(directory: root, beforeIndex: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await worker.value; XCTFail("Cancelled cleanup committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(Set(try HistoryTransactions.load(root).map(\.id)), Set(rows.map(\.id)))
    }
    func testPreparedAndCommittedPermanentJournalRecoverIdempotently() throws {
        for committed in [false, true] {
            let (root, rows) = try seed(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("history.json"), before = try Data(contentsOf: file)
            let after = Data("[]".utf8), folder = ".incoming-\(UUID())"
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
            let moves = rows.flatMap { [$0.filename, $0.projectFilename!] }.map { ["from": $0, "to": folder + "/" + $0] }
            // Prepared crash: one move finished. Committed crash: all moved, with
            // part of post-commit deletion already finished. These are disk states,
            // not a claim of SIGKILL or power-loss testing.
            for move in committed ? moves : Array(moves.prefix(1)) {
                try FileManager.default.moveItem(at: root.appendingPathComponent(move["from"]!), to: root.appendingPathComponent(move["to"]!))
            }
            if committed {
                try after.write(to: file)
                try FileManager.default.removeItem(at: root.appendingPathComponent(moves[0]["to"]!))
            }
            let journal: [String: Any] = ["id": UUID().uuidString, "before": hash(before), "after": hash(after), "moves": moves,
                                           "cleanupOnCommit": [folder], "cleanupOnRollback": [folder]]
            try JSONSerialization.data(withJSONObject: journal).write(to: root.appendingPathComponent(".history-transaction.json"))
            for _ in 0..<2 { XCTAssertEqual(try HistoryTransactions.load(root).count, committed ? 0 : 2) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path))
            for row in rows { XCTAssertEqual(FileManager.default.fileExists(atPath: root.appendingPathComponent(row.filename).path), !committed) }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("export.png")), Data("export must survive".utf8))
        }
    }
}
