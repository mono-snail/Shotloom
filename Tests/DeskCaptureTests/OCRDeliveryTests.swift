import XCTest
import AppKit
@testable import DeskCapture

@MainActor
final class OCRDeliveryTests: XCTestCase {
    func testRecognitionCannotOverwriteUserCorrectionOrNewClipboard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-delivery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(directory: root)
        let board = NSPasteboard(name: .init("OCR-delivery-test-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        let image = WorkflowCorpus.texture(width: 20, height: 20, seed: 42)
        let record = try await store.addAsync(image, mode: .region)
        var resume: CheckedContinuation<String, Never>?
        app.textRecognizerForDiagnostics = { _ in await withCheckedContinuation { resume = $0 } }
        app.recognize(record, copyAfter: true)
        let deadline = Date().addingTimeInterval(5)
        while resume == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try XCTUnwrap(resume)
        try store.setText("user corrected", for: record.id)
        board.clearContents(); board.setString("new clipboard", forType: .string)
        continuation.resume(returning: "late machine result")
        while app.isRecognizing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(app.isRecognizing)
        XCTAssertEqual(store.records.first?.recognizedText, "user corrected")
        XCTAssertEqual(board.string(forType: .string), "new clipboard")
    }
    func testCancelledRecognitionCanIndexButCannotDeliverToClipboard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(directory: root)
        let board = NSPasteboard(name: .init("OCR-cancel-test-\(UUID())")); defer { board.releaseGlobally() }
        board.setString("keep", forType: .string)
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        let record = try await store.addAsync(WorkflowCorpus.texture(width: 20, height: 20, seed: 42), mode: .region)
        var resume: CheckedContinuation<String, Never>?
        app.textRecognizerForDiagnostics = { _ in await withCheckedContinuation { resume = $0 } }
        app.recognize(record, copyAfter: true)
        let deadline = Date().addingTimeInterval(5)
        while resume == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try XCTUnwrap(resume)
        app.cancelCapture()
        continuation.resume(returning: "indexed text")
        while app.isRecognizing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(app.isRecognizing)
        XCTAssertEqual(store.records.first?.recognizedText, "indexed text")
        XCTAssertEqual(board.string(forType: .string), "keep")
    }
    func testLaterExternalClipboardWriteWinsWithoutEditingOCR() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-external-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(directory: root)
        let board = NSPasteboard(name: .init("OCR-external-test-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        let record = try await store.addAsync(WorkflowCorpus.texture(width: 20, height: 20, seed: 42), mode: .region)
        var resume: CheckedContinuation<String, Never>?
        app.textRecognizerForDiagnostics = { _ in await withCheckedContinuation { resume = $0 } }
        app.recognize(record, copyAfter: true)
        let deadline = Date().addingTimeInterval(5)
        while resume == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let continuation = try XCTUnwrap(resume)
        board.clearContents(); board.setString("new external copy", forType: .string)
        continuation.resume(returning: "index safely")
        while app.isRecognizing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(app.isRecognizing)
        XCTAssertEqual(store.records.first?.recognizedText, "index safely")
        XCTAssertEqual(board.string(forType: .string), "new external copy")
    }

}
