import XCTest
import AppKit
import SwiftUI
@testable import DeskCapture

final class ImageResizeTests: XCTestCase {
    private func image(width: Int = 1000, height: Int = 800) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
    private func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    @MainActor
    func testEveryCornerPreservesOppositeCornerAspectRatioAndSingleUndo() throws {
        for corner in 0..<4 {
            let document = AnnotationDocument(image: try image())
            document.addImage(try image(width: 400, height: 200))
            let original = document.marks
            let handles = document.imageResizeHandles(in: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let anchor = handles[(corner + 2) % 4]
            let delta = CGPoint(x: corner == 0 || corner == 3 ? -0.1 : 0.1, y: corner < 2 ? -0.0625 : 0.0625)
            document.resizeSelectedImage(from: original, corner: corner, by: delta)
            document.resizeSelectedImage(from: original, corner: corner, by: CGPoint(x: delta.x * 2, y: delta.y * 2))
            let resized = document.marks[0].points
            XCTAssertEqual((resized[1].x - resized[0].x) * 1000 / ((resized[1].y - resized[0].y) * 800), 2, accuracy: 0.0001)
            XCTAssertEqual(document.imageResizeHandles(in: CGRect(x: 0, y: 0, width: 1000, height: 800))[(corner + 2) % 4], anchor)
            document.commitMove(from: original)
            document.undo(); XCTAssertEqual(document.marks[0].points, original[0].points)
            document.redo(); XCTAssertEqual(document.marks[0].points, resized)
            let restored = try AnnotationDocument(projectData: document.projectData())
            XCTAssertEqual(restored.marks[0].points, resized)
        }
    }
    @MainActor
    func testResizeClampsAtCanvasEdgesAndDoesNotFlip() throws {
        let document = AnnotationDocument(image: try image())
        document.addImage(try image(width: 400, height: 200))
        let original = document.marks
        for delta in [CGPoint(x: 10, y: 10), CGPoint(x: -10, y: -10)] {
            document.resizeSelectedImage(from: original, corner: 2, by: delta)
            let points = document.marks[0].points
            XCTAssertGreaterThan(points[1].x, points[0].x)
            XCTAssertGreaterThan(points[1].y, points[0].y)
            for point in points { XCTAssertTrue((0...1).contains(point.x)); XCTAssertTrue((0...1).contains(point.y)) }
            XCTAssertEqual((points[1].x - points[0].x) * 1000 / ((points[1].y - points[0].y) * 800), 2, accuracy: 0.0001)
        }
    }
    @MainActor
    func testEditorCornerDragResizesInsteadOfMoving() throws {
        let document = AnnotationDocument(image: try image())
        document.addImage(try image(width: 400, height: 200))
        let canvas = AnnotationCanvas(document: document)
        canvas.frame = CGRect(x: 0, y: 0, width: 1048, height: 848)
        let rect = CGRect(x: 24, y: 24, width: 1000, height: 800)
        let start = document.imageResizeHandles(in: rect)[2]
        let before = document.marks[0].points
        let end = CGPoint(x: start.x + 100, y: start.y + 50)
        canvas.mouseDown(with: try mouse(.leftMouseDown, start))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end))
        canvas.mouseUp(with: try mouse(.leftMouseUp, end))
        XCTAssertEqual(document.marks[0].points[0], before[0])
        XCTAssertEqual(document.overlayPixelWidth, 500, accuracy: 0.001)
        document.undo(); XCTAssertEqual(document.marks[0].points, before)
    }
    @MainActor
    func testCaptureCornerDragResizesImageAndKeepsCaptureRegion() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: try image()), mode: .region, windows: [])
        let rect = CGRect(x: 40, y: 40, width: 400, height: 320)
        view.setInitialSelectionForPreview(rect)
        let document = try XCTUnwrap(view.document)
        document.addImage(try image(width: 100, height: 50))
        let toolbar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
        toolbar.rootView.state.selectingMark = true
        let start = document.imageResizeHandles(in: rect)[2]
        let before = document.marks[0].points
        let end = CGPoint(x: start.x + 25, y: start.y + 12.5)
        view.mouseDown(with: try mouse(.leftMouseDown, start))
        view.mouseDragged(with: try mouse(.leftMouseDragged, end))
        view.mouseUp(with: try mouse(.leftMouseUp, end))
        XCTAssertEqual(view.selection, rect)
        XCTAssertEqual(document.marks[0].points[0], before[0])
        XCTAssertGreaterThan(document.marks[0].points[1].x, before[1].x)
        document.undo(); XCTAssertEqual(document.marks[0].points, before)
    }
}
