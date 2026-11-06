import XCTest
import AppKit
@testable import DeskCapture

final class AnnotationSnapGuideTests: XCTestCase {
    func testNearestTargetsProduceGuidesAtActualSnappedCoordinates() {
        let result = AnnotationLayout.snap(.init(x: 0.323, y: 0.444), group: .init(x: 0.2, y: 0.2, width: 0.08, height: 0.1),
                                           targets: [.init(x: 0.6, y: 0.65, width: 0.16, height: 0.14)], tolerance: .init(width: 0.01, height: 0.01))
        XCTAssertEqual(result.delta.x, 0.32, accuracy: 0.0000001)
        XCTAssertEqual(result.delta.y, 0.45, accuracy: 0.0000001)
        XCTAssertEqual(result.guides, [.init(axis: .vertical, position: 0.6), .init(axis: .horizontal, position: 0.65)])
        XCTAssertEqual(result.guides(afterApplying: result.delta), result.guides)
        XCTAssertEqual(result.guides(afterApplying: .init(x: 0.3, y: result.delta.y)), [.init(axis: .horizontal, position: 0.65)])
    }

    func testCanvasCenterGuidesAndInvalidTargetsRespectExistingTolerance() {
        let group = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.1)
        let near = AnnotationLayout.snap(.init(x: 0.199, y: 0.02), group: group, targets: [.null, .infinite], tolerance: .init(width: 0.006, height: 0.006))
        XCTAssertEqual(near.delta.x, 0.2, accuracy: 0.0000001)
        XCTAssertEqual(near.guides, [.init(axis: .vertical, position: 0.5)])
        let far = AnnotationLayout.snap(.init(x: 0.19, y: 0.02), group: group, targets: [], tolerance: .init(width: 0.006, height: 0.006))
        XCTAssertTrue(far.guides.isEmpty)
        XCTAssertEqual(far.delta, .init(x: 0.19, y: 0.02))
        XCTAssertTrue(AnnotationLayout.snap(.zero, group: .null, targets: [], tolerance: .init(width: 1, height: 1)).guides.isEmpty)
    }

    @MainActor func testCanvasClampSuppressesUnachievedGuideAndDisablingSnapReturnsNoGuides() {
        let document = AnnotationDocument(image: WorkflowCorpus.texture(width: 200, height: 200, seed: 81))
        document.add(document.makeMark(tool: .step, points: [.init(x: 0.9, y: 0.4)])); document.selectAllMarks()
        let original = document.marks
        let guides = document.moveSelected(from: original, by: .init(x: 0.18, y: 0), snapTolerance: .init(width: 0.01, height: 0.001))
        XCTAssertEqual(document.marks.first?.points.first?.x, 1)
        XCTAssertTrue(guides.isEmpty, "Canvas clamping prevented the requested visual alignment")
        document.snapsAnnotations = false
        XCTAssertTrue(document.moveSelected(from: original, by: .init(x: -0.02, y: 0), snapTolerance: .init(width: 0.1, height: 0.1)).isEmpty)
        XCTAssertEqual(document.marks.first!.points.first!.x, 0.88, accuracy: 0.0000001)
    }

    @MainActor func testSlantedQuadraticSelectionUsesTrueExtremumAtBothImageAspects() throws {
        for (width, expectedMinX) in [(200, 43.42857142857143), (400, 112.71428571428571)] {
            let document = AnnotationDocument(image: WorkflowCorpus.texture(width: width, height: 200, seed: 82))
            var mark = document.makeMark(tool: .curvedArrow, points: [.init(x: 0.3, y: 0.3), .init(x: 0.5, y: 0.7)])
            mark.curvature = 0.7; document.add(mark); document.selectAllMarks()
            let selection = try XCTUnwrap(document.selectionBounds(in: CGRect(x: 0, y: 0, width: width, height: 200)))
            XCTAssertEqual(selection.minX, CGFloat(expectedMinX), accuracy: 0.0000001)
            XCTAssertEqual(selection.maxX, CGFloat(width) * 0.5 + 5, accuracy: 0.0000001)
        }
    }

    @MainActor func testNativeCanvasShowsTransientGuideWithoutExportingItAndClearsOnReleaseAndResign() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let document = AnnotationDocument(image: try XCTUnwrap(context.makeImage()))
        document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.2, y: 0.2), .init(x: 0.3, y: 0.3)]))
        document.selectingMark = true
        let canvas = AnnotationCanvas(document: document); canvas.frame = CGRect(x: 0, y: 0, width: 248, height: 248); canvas.imageDisplayScale = 1
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.close() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func guideStripeHasInk() throws -> Bool {
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            let sx = CGFloat(bitmap.pixelsWide) / 248, sy = CGFloat(bitmap.pixelsHigh) / 248
            for y in 110..<140 {
                for x in 123...125 {
                    let color = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * sx), y: Int(CGFloat(y) * sy))?.usingColorSpace(.deviceRGB))
                    if color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 { return true }
                }
            }
            return false
        }
        canvas.mouseDown(with: try event(.leftMouseDown, .init(x: 64, y: 74)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, .init(x: 104, y: 74)))
        XCTAssertEqual(canvas.snapGuides, [.init(axis: .vertical, position: 0.5)])
        XCTAssertTrue(try guideStripeHasInk(), "Real canvas draw must include the guide away from the annotation")
        let exported = NSBitmapImageRep(cgImage: try XCTUnwrap(document.render()))
        let exportColor = try XCTUnwrap(exported.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(exportColor.greenComponent, 0.99, "Guide is a view overlay, never exported pixels")
        canvas.mouseUp(with: try event(.leftMouseUp, .init(x: 104, y: 74)))
        XCTAssertTrue(canvas.snapGuides.isEmpty); XCTAssertFalse(try guideStripeHasInk())
        document.undo(); XCTAssertEqual(document.marks.first?.points, [.init(x: 0.2, y: 0.2), .init(x: 0.3, y: 0.3)])
        canvas.mouseDown(with: try event(.leftMouseDown, .init(x: 64, y: 74)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, .init(x: 104, y: 74)))
        XCTAssertFalse(canvas.snapGuides.isEmpty)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(canvas.snapGuides.isEmpty)
    }
}
