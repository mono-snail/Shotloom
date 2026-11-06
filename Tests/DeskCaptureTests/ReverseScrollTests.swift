import XCTest
import AppKit
@testable import DeskCapture

final class ReverseScrollTests: XCTestCase {
    func testReverseVerticalAndHorizontalPreserveAllPixelsAndUndoRecapture() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            let vertical = axis == .vertical
            let page = WorkflowCorpus.texture(width: vertical ? 400 : 1500, height: vertical ? 1500 : 400, seed: 42)
            let stitcher = try ScrollStitcher(axis: axis, direction: .reverse)
            func frame(_ start: Int) throws -> CGImage {
                try XCTUnwrap(page.cropping(to: CGRect(x: vertical ? 0 : start, y: vertical ? start : 0,
                                                      width: vertical ? 400 : 600, height: vertical ? 600 : 400)))
            }
            for (index, start) in [500, 387, 260, 187].enumerated() {
                XCTAssertEqual(try stitcher.append(frame(start)), index == 0 ? 600 : [0, 113, 127, 73][index])
            }
            let expected = try XCTUnwrap(page.cropping(to: CGRect(x: vertical ? 0 : 187, y: vertical ? 187 : 0,
                                                                width: vertical ? 400 : 913, height: vertical ? 913 : 400)))
            XCTAssertEqual(try pixels(stitcher.render()), try pixels(expected))
            XCTAssertEqual(stitcher.preview.tiles.map { vertical ? $0.sourceHeight : $0.sourceWidth }, [73, 127, 113, 600])
            XCTAssertEqual(try stitcher.append(frame(187)), 0)
            XCTAssertEqual(try stitcher.removeLast(), 73)
            XCTAssertEqual(stitcher.preview.tiles.map { vertical ? $0.sourceHeight : $0.sourceWidth }, [127, 113, 600])
            XCTAssertEqual(try stitcher.append(frame(160)), 100)
            let recaptured = try XCTUnwrap(page.cropping(to: CGRect(x: vertical ? 0 : 160, y: vertical ? 160 : 0,
                                                                  width: vertical ? 400 : 940, height: vertical ? 940 : 400)))
            XCTAssertEqual(try pixels(stitcher.render()), try pixels(recaptured))
        }
    }
    func testWrongDirectionAndUnrelatedFrameCannotDestroyAcceptedContent() throws {
        let page = WorkflowCorpus.texture(width: 400, height: 1500, seed: 42)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 300, width: 400, height: 600)))
        let up = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 187, width: 400, height: 600)))
        XCTAssertNil(ScrollMatcher.match(previous: first, next: up))
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: up, direction: .reverse)?.offset, 113)
        let stitcher = try ScrollStitcher(direction: .reverse)
        try stitcher.append(first); try stitcher.append(up)
        let accepted = try pixels(stitcher.render())
        XCTAssertNil(try stitcher.append(WorkflowCorpus.texture(width: 400, height: 600, seed: 987)))
        XCTAssertEqual(stitcher.frameCount, 2)
        XCTAssertEqual(try pixels(stitcher.render()), accepted)
        XCTAssertNil(try stitcher.append(WorkflowCorpus.texture(width: 401, height: 600, seed: 42)))
        XCTAssertEqual(try pixels(stitcher.render()), accepted)
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
}

extension ReverseScrollTests {
    @MainActor
    func testAutomaticScrollRejectsObscuredAndMissingTargets() {
        func window(_ id: UInt32, _ frame: CGRect) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowBounds as String: frame.dictionaryRepresentation,
             kCGWindowAlpha as String: 1.0]
        }
        let rect = CGRect(x: 100, y: 100, width: 400, height: 600)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let target = window(9, CGRect(x: 100, y: 300, width: 400, height: 600))
        let fullCover = window(12, screen)
        XCTAssertNil(ScrollCapture.unobscuredScrollPoint(rect: rect, screenFrame: screen, desktopTop: 1000,
                                                        target: 9, windows: [fullCover, target]))
        XCTAssertNil(ScrollCapture.unobscuredScrollPoint(rect: rect, screenFrame: screen, desktopTop: 1000,
                                                        target: 9, windows: []))
        let halfCover = window(12, CGRect(x: 100, y: 300, width: 220, height: 600))
        let point = ScrollCapture.unobscuredScrollPoint(rect: rect, screenFrame: screen, desktopTop: 1000,
                                                       target: 9, windows: [halfCover, target])
        XCTAssertEqual(point, CGPoint(x: 400, y: 600))
    }
    @MainActor
    func testReversePreviewFollowsTopAndPreservesReviewPosition() throws {
        let page = WorkflowCorpus.texture(width: 400, height: 1500, seed: 42)
        let stitcher = try ScrollStitcher(direction: .reverse)
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 500, width: 400, height: 600))))
        let scroll = ScrollPreviewScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 180))
        scroll.documentView = ScrollPreviewCanvas()
        scroll.update(preview: stitcher.preview, overview: false, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 70))
        let priorY = scroll.contentView.bounds.minY, priorHeight = scroll.documentView!.frame.height
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 387, width: 400, height: 600))))
        scroll.update(preview: stitcher.preview, overview: false, followsTail: false)
        XCTAssertEqual(scroll.contentView.bounds.minY, priorY + scroll.documentView!.frame.height - priorHeight, accuracy: 0.1)
        scroll.update(preview: stitcher.preview, overview: false, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.1)
    }
    func testReverseWheelAndRecoveryInstructionsUseCorrectDirection() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            let event = try XCTUnwrap(ScrollAutomationEvent.make(rect: CGRect(x: 20, y: 20, width: 600, height: 600),
                                                                 screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                                                 desktopTop: 1000, axis: axis, direction: .reverse))
            XCTAssertGreaterThan(event.getIntegerValueField(axis == .vertical ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2), 0)
            XCTAssertEqual(ScrollDirection.reverse.movementTitle(axis: axis), axis == .vertical ? L10n.text("向上") : L10n.text("向左"))
            XCTAssertEqual(ScrollDirection.reverse.recoveryTitle(axis: axis), axis == .vertical ? L10n.text("向下") : L10n.text("向右"))
        }
        XCTAssertFalse(StatusMenuState(capturing: true).allows(.upwardScroll))
        XCTAssertTrue(StatusMenuState().allows(.upwardScroll))
    }
}
