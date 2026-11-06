import XCTest
import AppKit
import AVFoundation
@testable import DeskCapture

final class EditorialTests: XCTestCase {
    private func image(_ color: NSColor) -> CGImage {
        let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(color.cgColor); c.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return c.makeImage()!
    }
    func testRepairUsesSurroundingBackgroundInsteadOfSelectedObject() throws {
        let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        c.setFillColor(NSColor.red.cgColor); c.fill(CGRect(x: 85, y: 35, width: 30, height: 30))
        let original = try XCTUnwrap(c.makeImage())
        let patch = try XCTUnwrap(CaptureRepair.patch(original, normalized: CGPoint(x: 0.35, y: 0.2), CGPoint(x: 0.65, y: 0.8)))
        XCTAssertEqual(CapturePixelColor.hex(patch, at: CGPoint(x: patch.width / 2, y: patch.height / 2)), "#FFFFFF")
        XCTAssertEqual(CapturePixelColor.hex(original, at: CGPoint(x: 100, y: 50)), "#FF0000")
    }
    @MainActor func testOverlayProjectAndUndoPreserveEmbeddedImage() throws {
        let document = AnnotationDocument(image: image(.white))
        document.addImage(image(.blue))
        document.opacity = 0.4
        let restored = try AnnotationDocument(projectData: document.projectData())
        XCTAssertEqual(restored.marks.count, 1)
        XCTAssertEqual(restored.marks[0].opacity, 0.4)
        XCTAssertNotNil(restored.marks[0].overlayImage)
        document.undo(); document.undo()
        XCTAssertTrue(document.marks.isEmpty)
    }
    @MainActor func testTextRewriteIsEditableAndUndoRestoresOriginal() async throws {
        let d = AnnotationDocument(image: image(.white))
        let originalBytes = d.original.dataProvider?.data
        await d.replaceOCRLine(OCRLine(text: "Before", bounds: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.2), confidence: 1), with: "After")
        XCTAssertEqual(d.marks.first?.text, "After")
        XCTAssertNotNil(d.marks.first?.overlayImage)
        let restored = try AnnotationDocument(projectData: d.projectData())
        XCTAssertEqual(restored.marks.first?.tool, .replace)
        XCTAssertEqual(restored.marks.first?.text, "After")
        XCTAssertEqual(d.original.dataProvider?.data, originalBytes)
        d.undo(); XCTAssertTrue(d.marks.isEmpty)
    }
    @MainActor func testTextStylesProduceDifferentPixelsAndPersist() throws {
        var outputs: Set<Data> = []
        for style in AnnotationTextStyle.allCases {
            let d = AnnotationDocument(image: image(.white)); d.textStyle = style; d.fontSize = 16
            d.add(d.makeMark(tool: .text, points: [CGPoint(x: 0.15, y: 0.4)], text: "DeskCapture"))
            let rendered = try XCTUnwrap(d.render())
            outputs.insert(try XCTUnwrap(rendered.dataProvider?.data) as Data)
            XCTAssertEqual(try AnnotationDocument(projectData: d.projectData()).marks.first?.textStyle, style)
        }
        XCTAssertEqual(outputs.count, AnnotationTextStyle.allCases.count)
    }
    @MainActor func testCurveCanBeSelectedAtItsBulge() {
        let d = AnnotationDocument(image: image(.white))
        d.curvature = 0.6
        d.add(d.makeMark(tool: .curvedArrow, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)]))
        d.selectMark(at: CGPoint(x: 0.5, y: 0.68), tolerance: CGPoint(x: 0.01, y: 0.01))
        XCTAssertNotNil(d.selectedMark)
    }
    @MainActor func testMultipleMarksMoveRestyleDuplicateAndUndoTogether() {
        let d = AnnotationDocument(image: image(.white))
        d.add(d.makeMark(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.3)]))
        d.add(d.makeMark(tool: .arrow, points: [CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.8, y: 0.8)]))
        d.selectMark(at: CGPoint(x: 0.2, y: 0.2), tolerance: .zero)
        d.selectMark(at: CGPoint(x: 0.7, y: 0.7), tolerance: .zero, additive: true)
        XCTAssertEqual(d.selectedMarkIDs.count, 2)
        let original = d.marks
        d.nudgeSelected(x: 10, y: 5)
        XCTAssertEqual(d.marks[0].points[0].x - original[0].points[0].x, 0.05, accuracy: 0.001)
        XCTAssertEqual(d.marks[1].points[0].x - original[1].points[0].x, 0.05, accuracy: 0.001)
        d.undo(); XCTAssertEqual(d.marks.map(\.points), original.map(\.points))
        d.lineWidth = 13; XCTAssertTrue(d.marks.allSatisfy { $0.width == 13 })
        d.duplicateSelected(); XCTAssertEqual(d.marks.count, 4)
        XCTAssertEqual(Set(d.marks.map(\.id)).count, 4)
        XCTAssertEqual(d.selectedMarkIDs.count, 2)
        d.deleteSelected(); XCTAssertEqual(d.marks.count, 2)
        d.undo(); XCTAssertEqual(d.marks.count, 4)
    }
    @MainActor func testLayerOrderingPreservesUnselectedMarksAndCanUndo() {
        let d = AnnotationDocument(image: image(.white))
        for x in [0.1, 0.4, 0.7] { d.add(d.makeMark(tool: .rectangle, points: [CGPoint(x: x, y: 0.1), CGPoint(x: x + 0.1, y: 0.2)])) }
        let ids = d.marks.map(\.id)
        d.selectMark(at: CGPoint(x: 0.15, y: 0.15), tolerance: .zero)
        d.reorderSelected(front: true)
        XCTAssertEqual(d.marks.map(\.id), [ids[1], ids[2], ids[0]])
        d.undo(); XCTAssertEqual(d.marks.map(\.id), ids)
        d.selectAllMarks(); d.selectMark(at: CGPoint(x: 0.15, y: 0.15), tolerance: .zero, additive: true)
        XCTAssertEqual(d.selectedMarkIDs.count, 2)
    }
    func testCaptionCutsMergeOverlapsAndRemapTime() throws {
        let captions = [CaptionSegment(start: 2, end: 4, text: "cut", keep: false),
                        CaptionSegment(start: 3, end: 5, text: "overlap", keep: false),
                        CaptionSegment(start: 5, end: 7, text: "保留字幕")]
        let plan = try VideoEditPlan(duration: 10, start: 1, end: 9, captions: captions)
        XCTAssertEqual(plan.duration, 5, accuracy: 0.001)
        XCTAssertNil(plan.map(3))
        XCTAssertEqual(try XCTUnwrap(plan.map(6)), 2, accuracy: 0.001)
        XCTAssertEqual(plan.mappedCaptions(captions).first?.start, 1)
        XCTAssertThrowsError(try VideoEditPlan(duration: 10, start: 2, end: 4, captions: captions))
    }
    func testSRTRoundTripKeepsMultilineAndMilliseconds() throws {
        let rows = [CaptionSegment(start: 1.234, end: 5.678, text: "第一行\nSecond line")]
        let decoded = try VideoTranscript.parseSRT(VideoTranscript.srt(rows))
        XCTAssertEqual(decoded.first?.text, rows.first?.text)
        XCTAssertEqual(decoded.first?.start, 1.234)
        XCTAssertEqual(decoded.first?.end, 5.678)
        XCTAssertThrowsError(try VideoTranscript.parseSRT("invalid"))
    }
    func testVideoCanvasDimensionsAreEvenAndKeepAspect() {
        for layout in VideoCanvasLayout.allCases {
            let size = layout.size(source: CGSize(width: 1920, height: 1080))
            XCTAssertEqual(Int(size.width) % 2, 0); XCTAssertEqual(Int(size.height) % 2, 0)
            if layout == .portrait { XCTAssertEqual(size.width / size.height, 9 / 16, accuracy: 0.002) }
            if layout == .square { XCTAssertEqual(size.width, size.height) }
        }
    }
    func testComparisonHasTwoDistinctFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try CaptureComparisonExporter.gif(before: image(.red), after: image(.blue), to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertEqual(CapturePixelColor.hex(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), at: CGPoint(x: 100, y: 50)), "#FF0000")
        XCTAssertEqual(CapturePixelColor.hex(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 1, nil)), at: CGPoint(x: 100, y: 50)), "#0000FF")
    }
    @MainActor func testPresetReloadIncludesCustomBackground() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BeautifyPresetStore(directory: dir)
        try await store.save(name: "Ocean", style: .frost, layout: .square, padding: 0.1, roundness: 0.02, background: image(.blue))
        let reloaded = BeautifyPresetStore(directory: dir)
        let preset = try XCTUnwrap(reloaded.presets.first)
        XCTAssertEqual(preset.name, "Ocean"); XCTAssertNotNil(reloaded.background(for: preset))
        try reloaded.remove(preset)
        XCTAssertTrue(BeautifyPresetStore(directory: dir).presets.isEmpty)
    }
}
