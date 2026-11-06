import XCTest
import AppKit
import PDFKit
@testable import DeskCapture

final class OutputCommitTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-output-commit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    func testCancellationDuringStagedWritePreservesExistingDestination() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.png"), original = Data("old output".utf8)
        try original.write(to: output)
        let task = Task.detached {
            try CaptureImageExport.writeEncoded(Data("new output".utf8), to: output, beforeCommit: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { try await task.value; XCTFail("Cancelled write must not commit") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.png"])
    }
    func testFailureAfterStagingLeavesNoNewDestination() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("new.txt")
        XCTAssertThrowsError(try CaptureImageExport.writeEncoded(Data("draft".utf8), to: output, beforeCommit: { throw CancellationError() }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testSuccessfulCommitReplacesAndCleansStage() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("result.txt")
        try Data("before".utf8).write(to: output)
        let replacement = Data("after".utf8)
        try CaptureImageExport.writeEncoded(replacement, to: output)
        XCTAssertEqual(try Data(contentsOf: output), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["result.txt"])
    }
    func testPDFSaveCopyDoesNotObserveSubsequentViewAnnotations() throws {
        let pdf = PDFDocument()
        let image = NSImage(cgImage: WorkflowCorpus.texture(width: 80, height: 60, seed: 12), size: .init(width: 80, height: 60))
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let sourceData = try XCTUnwrap(pdf.dataRepresentation())
        let annotation = PDFAnnotation(bounds: .init(x: 5, y: 5, width: 20, height: 15), forType: .text, withProperties: nil)
        try XCTUnwrap(pdf.page(at: 0)).addAnnotation(annotation)
        let snapshot = ClipboardSaveSnapshot.pdf(sourceData)
        let saved = try XCTUnwrap(PDFDocument(data: snapshot.encoded()))
        XCTAssertEqual(saved.pageCount, 1)
        XCTAssertTrue(try XCTUnwrap(saved.page(at: 0)).annotations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(pdf.page(at: 0)).annotations.contains { $0 === annotation })
    }
    func testTextSaveKeepsRequestedXMLEncoding() throws {
        let text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><root>中文</root>"
        let data = try ClipboardSaveSnapshot.text(text, xml: true).encoded()
        XCTAssertEqual(String(data: data, encoding: .utf16), text)
        XCTAssertEqual(try ClipboardSaveSnapshot.text("plain 中文", xml: false).encoded(), Data("plain 中文".utf8))
    }

    @MainActor
    func testPDFSaveIncludesLiveHighlightsAndRejectsLaterViewChanges() async throws {
        let base = PDFDocument()
        let image = NSImage(cgImage: WorkflowCorpus.texture(width: 80, height: 60, seed: 19), size: .init(width: 80, height: 60))
        base.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let note = PDFAnnotation(bounds: .init(x: 1, y: 1, width: 10, height: 10), forType: .text, withProperties: nil)
        note.contents = "existing note"
        try XCTUnwrap(base.page(at: 0)).addAnnotation(note)
        let sourceData = try XCTUnwrap(base.dataRepresentation())
        let document = try XCTUnwrap(PDFDocument(data: sourceData))
        let page = try XCTUnwrap(document.page(at: 0))
        // PDFKit may serialize a text note with its own popup annotation.
        let baselineCount = page.annotations.count
        let highlight = PDFAnnotation(bounds: .init(x: 10, y: 20, width: 40, height: 12), forType: .highlight, withProperties: nil)
        highlight.color = .systemYellow; page.addAnnotation(highlight)
        let snapshot = try ClipboardSaveSnapshot.capturePDF(sourceData: sourceData, document: document, highlights: [(page, highlight)])
        page.removeAnnotation(highlight)
        let later = PDFAnnotation(bounds: .init(x: 2, y: 2, width: 20, height: 20), forType: .circle, withProperties: nil)
        page.addAnnotation(later)
        let data = try await Task.detached { try snapshot.encoded() }.value
        let saved = try XCTUnwrap(PDFDocument(data: data))
        let annotations = try XCTUnwrap(saved.page(at: 0)).annotations
        XCTAssertEqual(annotations.count, baselineCount + 1)
        XCTAssertEqual(annotations.filter { $0.type == "Highlight" }.count, 1)
        XCTAssertTrue(annotations.contains { $0.contents == "existing note" })
        XCTAssertFalse(annotations.contains { $0.type == "Circle" })
        XCTAssertEqual(page.annotations.count, baselineCount + 1)
        XCTAssertTrue(page.annotations.contains { $0 === later })
        XCTAssertFalse(page.annotations.contains { $0.type == "Highlight" })
    }
}
