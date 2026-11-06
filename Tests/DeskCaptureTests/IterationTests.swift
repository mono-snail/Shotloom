import XCTest
import AppKit
import CoreImage
@testable import DeskCapture

final class IterationTests: XCTestCase {
    @MainActor
    func testFavoriteColorsPersistDeduplicateAndBoundStorage() throws {
        let name = "DeskCapture-palette-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let store = AnnotationPresetStore(defaults: defaults)
        store.addColor("#abcdef"); store.addColor("#ABCDEF"); store.addColor("broken")
        XCTAssertEqual(store.colors, ["#ABCDEF"])
        for value in 0..<15 { store.addColor(String(format: "#%06X", value)) }
        XCTAssertEqual(store.colors.count, 12)
        XCTAssertEqual(AnnotationPresetStore(defaults: defaults).colors, store.colors)
        store.removeColor(store.colors[0]); XCTAssertEqual(store.colors.count, 11)
        XCTAssertEqual(AnnotationPresetStore.hex(try XCTUnwrap(AnnotationPresetStore.color("#123456"))), "#123456")
    }
    @MainActor
    func testSavedStyleConfiguresNextMarkAndPreservesSelectedOriginal() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let document = AnnotationDocument(image: try XCTUnwrap(context.makeImage()))
        document.customColor = .red; document.lineWidth = 12; document.fill = .solid
        let style = SavedAnnotationStyle(name: "Red box", tool: .rectangle, document: document)
        document.customColor = .blue; document.lineWidth = 3; document.fill = .outline
        let mark = document.makeMark(tool: .ellipse, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)])
        document.add(mark); document.selectAllMarks()
        style.apply(to: document)
        XCTAssertEqual(document.marks[0].width, 3); XCTAssertEqual(document.marks[0].tool, .ellipse)
        XCTAssertEqual(document.marks[0].color, .blue)
        XCTAssertTrue(document.selectedMarkIDs.isEmpty)
        let next = document.makeMark(tool: document.tool, points: [.zero, CGPoint(x: 1, y: 1)])
        XCTAssertEqual(next.width, 12); XCTAssertEqual(next.fill, .solid); XCTAssertEqual(next.tool, .rectangle)
        let decoded = try JSONDecoder().decode(SavedAnnotationStyle.self, from: JSONEncoder().encode(style))
        XCTAssertTrue(decoded.valid); XCTAssertEqual(decoded.name, style.name)
    }
    func testDrawingTimelinePreservesAppearanceClearAndBackwardSeek() throws {
        var mark = Annotation(tool: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)])
        mark.color = .red; mark.fill = .solid
        let timeline = RecordingDrawingTimeline(frames: [RecordingDrawingFrame(time: 0.5, marks: [AnnotationArchive(mark)]), RecordingDrawingFrame(time: 1.5, marks: [])])
        XCTAssertNil(timeline.index(at: 0.4)); XCTAssertEqual(timeline.index(at: 1), 0); XCTAssertEqual(timeline.index(at: 2), 1)
        let cache = RecordingDrawingCache(timeline)
        XCTAssertNil(cache.image(at: 0.4, size: CGSize(width: 100, height: 100)))
        let image = try XCTUnwrap(cache.image(at: 1, size: CGSize(width: 100, height: 100)))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        XCTAssertEqual(CapturePixelColor.hex(cg, at: CGPoint(x: 50, y: 50)), "#FF0000")
        XCTAssertNil(cache.image(at: 2, size: CGSize(width: 100, height: 100)))
        XCTAssertNotNil(cache.image(at: 1, size: CGSize(width: 100, height: 100)))
        let plan = try VideoEditPlan(duration: 3, start: 1, end: 3, captions: [])
        XCTAssertEqual(RecordingEffectsExporter.sourceTime(0, plan: plan), 1)
        XCTAssertNotNil(cache.image(at: RecordingEffectsExporter.sourceTime(0, plan: plan), size: CGSize(width: 100, height: 100)))
    }
    @MainActor
    func testDynamicSystemColorArchiveResolvesAndPreservesAppearance() throws {
        var mark = Annotation(tool: .arrow, points: [.zero, CGPoint(x: 1, y: 1)])
        mark.color = .systemRed
        let archive = AnnotationArchive(mark)
        let decoded = try JSONDecoder().decode(AnnotationArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(decoded.sRGB, true)
        let original = try XCTUnwrap(AnnotationPresetStore.hex(mark.color))
        XCTAssertEqual(AnnotationPresetStore.hex(decoded.makeMark().color), original)
    }
    @MainActor
    func testScrollWindowGeometryRejectsMovementAndResize() {
        let rect = CGRect(x: 100, y: 200, width: 400, height: 300)
        XCTAssertTrue(ScrollCapture.targetUnchanged(rect, rect))
        XCTAssertFalse(ScrollCapture.targetUnchanged(rect, rect.offsetBy(dx: 5, dy: 0)))
        XCTAssertFalse(ScrollCapture.targetUnchanged(rect, rect.insetBy(dx: 0, dy: 10)))
    }
}
