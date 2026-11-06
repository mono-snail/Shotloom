import XCTest
import AppKit
@testable import DeskCapture

final class EditorZoomTests: XCTestCase {
    func testFitUsesBothDimensionsAndLeavesPadding() {
        let viewport = CGSize(width: 800, height: 600)
        XCTAssertEqual(EditorZoomGeometry.scale(image: CGSize(width: 2000, height: 1000), viewport: viewport, zoom: nil), 0.376, accuracy: 0.0001)
        XCTAssertEqual(EditorZoomGeometry.scale(image: CGSize(width: 100, height: 10000), viewport: viewport, zoom: nil), 0.0552, accuracy: 0.0001)
        XCTAssertEqual(EditorZoomGeometry.scale(image: CGSize(width: 2000, height: 1000), viewport: viewport, zoom: 1), 1)
    }

    func testZoomPreservesImagePointAtViewportCenterAndClampsEdges() {
        let image = CGSize(width: 2000, height: 1000), viewport = CGSize(width: 800, height: 600)
        let size = EditorZoomGeometry.canvasSize(image: image, viewport: viewport, scale: 2)
        let origin = EditorZoomGeometry.origin(center: CGPoint(x: 0.7, y: 0.4), image: image, canvas: size, viewport: viewport, scale: 2)
        XCTAssertEqual((origin.x + viewport.width / 2 - 24) / 4000, 0.7, accuracy: 0.0001)
        XCTAssertEqual((origin.y + viewport.height / 2 - 24) / 2000, 0.4, accuracy: 0.0001)
        XCTAssertEqual(EditorZoomGeometry.origin(center: .zero, image: image, canvas: size, viewport: viewport, scale: 2), .zero)
        let end = EditorZoomGeometry.origin(center: CGPoint(x: 1, y: 1), image: image, canvas: size, viewport: viewport, scale: 2)
        XCTAssertEqual(end, CGPoint(x: size.width - viewport.width, y: size.height - viewport.height))
    }

    @MainActor
    func testScrollableCanvasZoomAndFitDoNotChangeExportOrAnnotations() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let document = AnnotationDocument(image: try XCTUnwrap(context.makeImage()))
        document.add(document.makeMark(tool: .rectangle, points: [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.6, y: 0.7)]))
        let originalMarks = document.marks
        let originalExport = ScrollMatcher.grayscale(try XCTUnwrap(document.render()))
        let scroll = EditorCanvasScrollView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let canvas = AnnotationCanvas(document: document)
        scroll.documentView = canvas
        scroll.update(zoom: 2)
        XCTAssertEqual(canvas.imageDisplayScale, 2)
        XCTAssertGreaterThan(canvas.frame.width, scroll.contentView.bounds.width)
        XCTAssertGreaterThan(canvas.frame.height, scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 800, y: 400))
        let viewport = scroll.contentView.bounds
        let center = CGPoint(x: (viewport.midX - 24) / 2400, y: (viewport.midY - 24) / 1600)
        scroll.update(zoom: 1)
        XCTAssertEqual((scroll.contentView.bounds.midX - 24) / 1200, center.x, accuracy: 0.001)
        XCTAssertEqual((scroll.contentView.bounds.midY - 24) / 800, center.y, accuracy: 0.001)
        scroll.update(zoom: nil)
        XCTAssertEqual(canvas.frame.size, scroll.contentView.bounds.size)
        XCTAssertEqual(document.marks.map(\.id), originalMarks.map(\.id))
        XCTAssertEqual(document.marks.map(\.points), originalMarks.map(\.points))
        let exported = try XCTUnwrap(document.render())
        XCTAssertEqual(ScrollMatcher.grayscale(exported), originalExport)
        XCTAssertEqual(exported.width, 1200)
        XCTAssertEqual(exported.height, 800)
    }
}
