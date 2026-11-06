import XCTest
@testable import DeskCapture

final class WorkflowFileCommitTests: XCTestCase {
    func testFailedAndCancelledCommitsPreserveExistingDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-workflow-commit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.txt"), original = Data("existing delivery".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try LocalWorkflowFiles.write(Data("failed output".utf8), to: destination, beforeCommit: { throw CaptureError.message("injected failure") }))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let cancelled = Task.detached {
            try LocalWorkflowFiles.write(Data(repeating: 65, count: 1_000_000), to: destination, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { try await cancelled.value; XCTFail("Cancelled export committed") } catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
        let replacement = Data("completed output".utf8)
        try LocalWorkflowFiles.write(replacement, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
    }

    func testFilesystemCommitFailurePreservesExistingDirectoryAndContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-workflow-commit-error-\(UUID())")
        let destination = root.appendingPathComponent("existing"), sentinel = destination.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try LocalWorkflowFiles.write(Data("replacement".utf8), to: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [destination.lastPathComponent])
    }
}
