import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import DeskCapture

@MainActor final class CanvasPixelLifecycleTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<128 { context.setFillColor(red: CGFloat(x) / 128, green: 0.2, blue: 0.3, alpha: 1); context.fill(CGRect(x: x, y: 0, width: 1, height: 96)) }
        return try XCTUnwrap(context.makeImage())
    }
    private func repair(_ document: AnnotationDocument) -> Annotation { document.makeMark(tool: .erase, points: [.init(x: 0.2, y: 0.2), .init(x: 0.45, y: 0.6)]) }
    func testInteractiveRepairCommitsPreparedPixelsAsOneUndo() async throws {
        let document = AnnotationDocument(image: try image()); document.addOnCanvas(repair(document))
        XCTAssertTrue(document.preparingPixels); XCTAssertTrue(document.marks.isEmpty)
        await document.waitForCanvasPixels()
        XCTAssertFalse(document.preparingPixels); XCTAssertNil(document.pixelPreparationError); XCTAssertEqual(document.marks.count, 1)
        let png = try XCTUnwrap(document.marks.first?.overlayPNG); XCTAssertNotNil(document.marks.first?.overlayImage)
        document.undo(); XCTAssertTrue(document.marks.isEmpty); XCTAssertFalse(document.canUndo)
        document.redo(); XCTAssertEqual(document.marks.first?.overlayPNG, png)
    }
    func testUndoCancelsPendingRepairWithoutPoppingOlderEdit() async throws {
        let document = AnnotationDocument(image: try image())
        document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.1, y: 0.1), .init(x: 0.15, y: 0.15)]))
        let old = document.marks.first?.id
        document.addOnCanvas(repair(document)); let work = try XCTUnwrap(document.canvasPixelWorkForDiagnostics())
        document.undo(); await work.value
        XCTAssertEqual(document.marks.map(\.id), [try XCTUnwrap(old)])
        XCTAssertFalse(document.preparingPixels)
        document.undo(); XCTAssertTrue(document.marks.isEmpty)
    }
    func testLateRepairCannotOverwriteAnotherEditOrClosedOwner() async throws {
        let document = AnnotationDocument(image: try image())
        document.beforePixelCommitForDiagnostics = { document.add(document.makeMark(tool: .rectangle, points: [.zero, .init(x: 0.1, y: 0.1)])) }
        document.addOnCanvas(repair(document)); await document.waitForCanvasPixels()
        XCTAssertEqual(document.marks.map(\.tool), [.rectangle])
        let closed = AnnotationDocument(image: try image())
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 128, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.orderFrontRegardless(); defer { window.close() }
        XCTAssertTrue(window.isVisible); closed.presentationWindow = window
        closed.beforePixelCommitForDiagnostics = { window.close() }
        closed.addOnCanvas(repair(closed)); let work = try XCTUnwrap(closed.canvasPixelWorkForDiagnostics()); await work.value
        XCTAssertTrue(closed.marks.isEmpty); XCTAssertFalse(closed.canUndo)
    }
    func testCancelledMoveKeepsOriginalPatchThenSuccessfulMoveHasOneUndo() async throws {
        let document = AnnotationDocument(image: try image())
        document.addOnCanvas(repair(document)); await document.waitForCanvasPixels()
        document.selectMark(at: .init(x: 0.3, y: 0.3), tolerance: .zero)
        let original = document.marks, png = try XCTUnwrap(original.first?.overlayPNG)
        document.moveSelected(from: original, by: .init(x: 0.15, y: 0))
        document.beforePixelCommitForDiagnostics = { document.cancelPixelPreparation() }
        document.commitMoveOnCanvas(from: original); let cancelled = try XCTUnwrap(document.canvasPixelWorkForDiagnostics()); await cancelled.value
        XCTAssertEqual(document.marks.first?.points, original.first?.points); XCTAssertEqual(document.marks.first?.overlayPNG, png)
        document.beforePixelCommitForDiagnostics = nil
        document.moveSelected(from: original, by: .init(x: 0.15, y: 0)); document.commitMoveOnCanvas(from: original); await document.waitForCanvasPixels()
        XCTAssertNotEqual(document.marks.first?.points, original.first?.points); XCTAssertNotEqual(document.marks.first?.overlayPNG, png)
        document.undo(); XCTAssertEqual(document.marks.first?.points, original.first?.points); XCTAssertEqual(document.marks.first?.overlayPNG, png)
    }
    func testLiftAndOverlayEncodingAreAtomicAndDeliveryRejectsStaleSnapshot() async throws {
        let document = AnnotationDocument(image: try image())
        document.liftContentOnCanvas(from: .init(x: 0.2, y: 0.2), to: .init(x: 0.7, y: 0.7)); await document.waitForCanvasPixels()
        XCTAssertEqual(document.marks.map(\.tool), [.erase, .image]); XCTAssertTrue(document.marks.allSatisfy { $0.overlayPNG != nil })
        document.undo(); XCTAssertTrue(document.marks.isEmpty)
        document.addImageOnCanvas(try image()); await document.waitForCanvasPixels()
        XCTAssertEqual(document.selectedMark?.tool, .image); XCTAssertNotNil(document.selectedMark?.overlayPNG)
        var deliveries = 0
        document.beforePixelCommitForDiagnostics = { document.undo() }
        document.renderForDelivery { _ in deliveries += 1 }; let work = try XCTUnwrap(document.canvasPixelWorkForDiagnostics()); await work.value
        XCTAssertEqual(deliveries, 0)
    }
    private func loadPNG(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: CaptureError.message("Provider returned no PNG or error")) }
            }
        }
    }
    func testDragProviderDeliversPNGWithoutUsingSystemClipboardAndRejectsOldRevision() async throws {
        let document = AnnotationDocument(image: try image())
        let provider = document.outputDragProvider()
        let bytes = try await loadPNG(provider)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 128); XCTAssertEqual(decoded.height, 96)
        let stale = document.outputDragProvider()
        document.add(document.makeMark(tool: .rectangle, points: [.zero, .init(x: 0.1, y: 0.1)]))
        do { _ = try await loadPNG(stale); XCTFail("A stale drag snapshot was delivered") } catch {}
    }
    func testFailedPixelPreparationDoesNotAppendOrCreateUndoEntry() async throws {
        let document = AnnotationDocument(image: try image())
        let mark = document.makeMark(tool: .erase, points: [.init(x: -0.1, y: 0.2), .init(x: 0.4, y: 0.5)])
        document.addOnCanvas(mark); await document.waitForCanvasPixels()
        XCTAssertTrue(document.marks.isEmpty); XCTAssertFalse(document.canUndo); XCTAssertNotNil(document.pixelPreparationError)
    }

}
