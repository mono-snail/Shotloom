import XCTest
import AppKit
@testable import DeskCapture

@MainActor
final class OCRRewriteLifecycleTests: XCTestCase {
    private func fixture() -> (AnnotationDocument, OCRLine) {
        let image = WorkflowCorpus.text("Before", font: "HelveticaNeue", width: 500, height: 180)
        return (AnnotationDocument(image: image), OCRLine(text: "Before", bounds: CGRect(x: 0.08, y: 0.4, width: 0.7, height: 0.3), confidence: 1))
    }
    func testEditingDuringPreparationRejectsLateReplacement() async {
        let (document, line) = fixture()
        document.beforeOCRReplacementCommitForDiagnostics = {
            document.add(Annotation(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)]))
        }
        await document.replaceOCRLine(line, with: "After")
        document.beforeOCRReplacementCommitForDiagnostics = nil
        XCTAssertEqual(document.marks.map(\.tool), [.rectangle])
        XCTAssertFalse(document.replacingOCR)
    }
    func testCancellationPreservesOriginalAndUndoHistory() async {
        let (document, line) = fixture()
        document.beforeOCRReplacementCommitForDiagnostics = { document.cancelOCRReplacement() }
        await document.replaceOCRLine(line, with: "After")
        document.beforeOCRReplacementCommitForDiagnostics = nil
        XCTAssertTrue(document.marks.isEmpty)
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.replacingOCR)
    }
    func testClosingOwningWindowRejectsLateReplacement() async {
        let (document, line) = fixture()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "DeskCapture generated rewrite fixture"
        window.orderFront(nil); document.presentationWindow = window
        document.beforeOCRReplacementCommitForDiagnostics = { window.close() }
        await document.replaceOCRLine(line, with: "After")
        document.beforeOCRReplacementCommitForDiagnostics = nil
        window.close()
        XCTAssertTrue(document.marks.isEmpty)
    }
    func testUnreadablyLongReplacementDoesNotCommit() async {
        let (document, line) = fixture()
        await document.replaceOCRLine(line, with: String(repeating: "W", count: 2000))
        XCTAssertTrue(document.marks.isEmpty)
        XCTAssertNotNil(document.ocrReplacementError)
    }
    func testFittedReplacementRoundTripsAsOneUndoableEdit() async throws {
        let (document, line) = fixture()
        document.ocrFontFits[line.id] = .init(fontName: "HelveticaNeue", sizePixels: 22, trackingPixels: 0.25,
            baselinePixels: 88, originXPixels: 40, weight: 0, maskError: 0.05)
        await document.replaceOCRLine(line, with: "After")
        let mark = try XCTUnwrap(document.marks.first)
        XCTAssertEqual(mark.fontName, "HelveticaNeue")
        XCTAssertEqual(mark.fontTracking, 0.25)
        XCTAssertNotNil(mark.overlayPNG)
        XCTAssertNotNil(mark.textOriginOffset)
        let restored = try AnnotationDocument(projectData: document.projectData())
        XCTAssertEqual(restored.marks.first?.textOriginOffset, mark.textOriginOffset)
        document.undo(); XCTAssertTrue(document.marks.isEmpty)
        document.redo(); XCTAssertEqual(document.marks.first?.text, "After")
    }
}
