import XCTest
import AppKit
@testable import DeskCapture

final class ScrollFixedEdgeTests: XCTestCase {
    func testDistributedBoundaryChangesAreNotTreatedAsOnePlayingThumbnail() throws {
        let page = WorkflowCorpus.texture(width: 480, height: 1400, seed: 42)
        let header = WorkflowCorpus.texture(width: 480, height: 36, seed: 777)
        func frame(_ start: Int, phase: UInt64) throws -> CGImage {
            let body = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: start, width: 480, height: 600)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 600, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(body, in: CGRect(x: 0, y: 0, width: 480, height: 600))
            for x in [0, 384] {
                context.draw(WorkflowCorpus.texture(width: 96, height: 96, seed: phase),
                             in: CGRect(x: x, y: 600 - (213 - start) - 96, width: 96, height: 96))
            }
            return try join([header, XCTUnwrap(context.makeImage())], axis: .vertical)
        }
        XCTAssertFalse(try ScrollFixedEdgeDetector.bodyBoundariesAgree(previous: frame(100, phase: 11), next: frame(213, phase: 99),
            edges: ScrollFixedEdges(leading: 36), axis: .vertical, direction: .forward, offset: 113))
    }

    func testPlayingThumbnailAtEitherBodyBoundaryKeepsFixedHeaderCaptureMoving() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            for direction in ScrollDirection.allCases {
                for videoStart in [213, 604] {
                    let vertical = axis == .vertical
                    let page = WorkflowCorpus.texture(width: vertical ? 480 : 1600, height: vertical ? 1600 : 480, seed: 42)
                    let header = WorkflowCorpus.texture(width: vertical ? 480 : 36, height: vertical ? 36 : 480, seed: 777)
                    func frame(_ start: Int, phase: UInt64) throws -> CGImage {
                        let body = try XCTUnwrap(page.cropping(to: vertical
                            ? CGRect(x: 0, y: start, width: 480, height: 600)
                            : CGRect(x: start, y: 0, width: 600, height: 480)))
                        let width = body.width, height = body.height
                        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(body, in: CGRect(x: 0, y: 0, width: width, height: height))
                        let video = WorkflowCorpus.texture(width: 96, height: 96, seed: phase)
                        context.draw(video, in: vertical
                            ? CGRect(x: 96, y: 600 - (videoStart - start) - 96, width: 96, height: 96)
                            : CGRect(x: videoStart - start, y: 96, width: 96, height: 96))
                        return try join([header, XCTUnwrap(context.makeImage())], axis: axis)
                    }
                    let first = try frame(direction == .forward ? 100 : 213, phase: 11)
                    let second = try frame(direction == .forward ? 213 : 100, phase: 99)
                    let edges = ScrollFixedEdges(leading: 36)
                    XCTAssertTrue(try ScrollFixedEdgeDetector.bodyBoundariesAgree(previous: first, next: second,
                        edges: edges, axis: axis, direction: direction, offset: 113))
                    let model = try ScrollStitcher(axis: axis, direction: direction, fixedEdges: edges, detectsFixedEdges: false)
                    try model.append(first)
                    XCTAssertEqual(try model.append(second), 113)
                    XCTAssertEqual(model.frameCount, 2)
                    XCTAssertEqual(vertical ? model.totalHeight : model.totalWidth, 749)
                }
            }
        }
    }

    func testWorkerAutomaticallyKeepsProvenFixedHeaderOnceAndAcceptsHoverChanges() async throws {
        let page = WorkflowCorpus.texture(width: 400, height: 1400, seed: 42)
        let bar = WorkflowCorpus.texture(width: 400, height: 36, seed: 777)
        func body(_ start: Int, _ length: Int) throws -> CGImage {
            try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: start, width: 400, height: length)))
        }
        func frame(_ start: Int, changedHeader: Bool = false) throws -> CGImage {
            try join([changedHeader ? WorkflowCorpus.texture(width: 400, height: 36, seed: 888) : bar, body(start, 564)], axis: .vertical)
        }
        let worker = ScrollCaptureWorker(try ScrollStitcher())
        _ = try await worker.append(frame(100))
        let resolved = try await worker.append(frame(213))
        XCTAssertEqual(resolved.frames, 2); XCTAssertEqual(resolved.increment, 113)
        XCTAssertEqual(resolved.fixedEdges, ScrollFixedEdges(leading: 36))
        XCTAssertNil(resolved.suggestedFixedEdges)
        let hovered = try await worker.append(frame(340, changedHeader: true))
        XCTAssertEqual(hovered.frames, 3); XCTAssertEqual(hovered.increment, 127)
        let rendered = try await worker.render()
        XCTAssertEqual(try pixels(rendered), try pixels(join([bar, body(100, 804)], axis: .vertical)))
    }

    func testWorkerDoesNotAutomaticallyDeleteARepeatedHeadline() async throws {
        let raw = WorkflowCorpus.texture(width: 400, height: 1400, seed: 42)
        let headline = WorkflowCorpus.texture(width: 400, height: 36, seed: 777)
        func slice(_ start: Int, _ length: Int) throws -> CGImage {
            try XCTUnwrap(raw.cropping(to: CGRect(x: 0, y: start, width: 400, height: length)))
        }
        let page = try join([slice(0, 100), headline, slice(136, 77), headline, slice(249, 1151)], axis: .vertical)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 100, width: 400, height: 600)))
        let next = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 213, width: 400, height: 600)))
        let worker = ScrollCaptureWorker(try ScrollStitcher())
        _ = try await worker.append(first)
        let update = try await worker.append(next)
        XCTAssertEqual(update.frames, 1); XCTAssertNil(update.increment)
        XCTAssertNotNil(update.suggestedFixedEdges)
        XCTAssertEqual(update.fixedEdges, .none)
        let rendered = try await worker.render()
        XCTAssertEqual(try pixels(rendered), try pixels(first))
    }

    func testPreviewSeparatorAndBlankPaddingDoNotBecomeNineteenPixelBar() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("preview-separator-before"), next = try image("preview-separator-after-320")
        XCTAssertEqual(ScrollFixedEdgeDetector.detect(previous: first, next: next, axis: .vertical, offset: 320), .none)
    }

    func testRealTextEditGlyphsDoNotBecomeAThinFixedBar() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-false-fixed-before"), next = try image("textedit-false-fixed-after-158")
        XCTAssertEqual(ScrollFixedEdgeDetector.detect(previous: first, next: next, axis: .vertical, offset: 158), .none)
    }

    func testUnconfiguredTinyFramesKeepOriginalCaptureBehavior() throws {
        let tiny = WorkflowCorpus.texture(width: 12, height: 12, seed: 42)
        let single = try ScrollStitcher(); try single.append(tiny)
        XCTAssertEqual(try pixels(single.render()), try pixels(tiny))
        let page = WorkflowCorpus.texture(width: 400, height: 100, seed: 42)
        let model = try ScrollStitcher()
        try model.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 40))))
        XCTAssertEqual(try model.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 31, width: 400, height: 40)))), 31)
        XCTAssertEqual(try pixels(model.render()), try pixels(XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 71)))))
    }
    @MainActor
    func testFixedBordersAreNotCountedAsCaptureFrames() throws {
        let stitcher = try ScrollStitcher(fixedEdges: ScrollFixedEdges(leading: 36, trailing: 28), detectsFixedEdges: false)
        try stitcher.append(WorkflowCorpus.texture(width: 400, height: 600, seed: 42))
        let model = ScrollCapture(stitcher: stitcher)
        XCTAssertEqual(model.frames, 1)
        let canvas = ScrollPreviewCanvas()
        canvas.preview = model.preview
        XCTAssertEqual(canvas.accessibilityLabel(), L10n.text("已拼接长图预览，\(model.preview.width) × \(model.preview.height) 像素，\(1) 段"))
    }
    func testInternalScrollPaneKeepsMovingWhenMostOfWindowIsStationary() async throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            for direction in ScrollDirection.allCases {
                let vertical = axis == .vertical
                let page = WorkflowCorpus.texture(width: vertical ? 240 : 1600, height: vertical ? 1600 : 240, seed: 42)
                let sidebar = WorkflowCorpus.texture(width: vertical ? 400 : 560, height: vertical ? 560 : 400, seed: 91)
                let header = WorkflowCorpus.texture(width: vertical ? 640 : 48, height: vertical ? 48 : 640, seed: 92)
                let footer = WorkflowCorpus.texture(width: vertical ? 640 : 32, height: vertical ? 32 : 640, seed: 93)
                func body(_ start: Int, length: Int = 560) throws -> CGImage {
                    try XCTUnwrap(page.cropping(to: vertical
                        ? CGRect(x: 0, y: start, width: 240, height: length)
                        : CGRect(x: start, y: 0, width: length, height: 240)))
                }
                func frame(_ start: Int) throws -> CGImage {
                    let content = try join([sidebar, body(start)], axis: vertical ? .horizontal : .vertical)
                    return try join([header, content, footer], axis: axis)
                }
                let start = direction == .forward ? 100 : 213
                let second = direction == .forward ? 213 : 100
                let third = direction == .forward ? 340 : 0
                let worker = ScrollCaptureWorker(try ScrollStitcher(axis: axis, direction: direction))
                _ = try await worker.append(frame(start))
                let update = try await worker.append(frame(second))
                XCTAssertEqual(update.increment, 113)
                XCTAssertEqual(update.fixedEdges, ScrollFixedEdges(leading: 48, trailing: 32))
                XCTAssertNil(update.suggestedFixedEdges)
                let continued = try await worker.append(frame(third))
                XCTAssertEqual(continued.increment, abs(third - second))
                let rendered = try await worker.render()
                let length = 560 + abs(start - third)
                let content = try XCTUnwrap(rendered.cropping(to: vertical
                    ? CGRect(x: 400, y: 48, width: 240, height: length)
                    : CGRect(x: 48, y: 400, width: length, height: 240)))
                XCTAssertEqual(try pixels(content), try pixels(body(min(start, third), length: length)))
            }
        }
    }

    func testIndependentPanesWithConflictingOffsetsAreNotOneMotionRegion() throws {
        let page = WorkflowCorpus.texture(width: 320, height: 1600, seed: 42)
        func pane(_ start: Int) throws -> CGImage {
            try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: start, width: 320, height: 600)))
        }
        let previous = try join([pane(100), pane(100)], axis: .horizontal)
        let next = try join([pane(213), pane(260)], axis: .horizontal)
        XCTAssertNil(try ScrollMotionRegion.detect(previous: previous, next: next, axis: .vertical, direction: .forward))
    }

    private func join(_ pieces: [CGImage], axis: ScrollAxis) throws -> CGImage {
        let width = axis == .vertical ? pieces[0].width : pieces.reduce(0) { $0 + $1.width }
        let height = axis == .vertical ? pieces.reduce(0) { $0 + $1.height } : pieces[0].height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var position = 0
        for image in pieces {
            ctx.draw(image, in: axis == .vertical ? CGRect(x: 0, y: height - position - image.height, width: width, height: image.height) : CGRect(x: position, y: 0, width: image.width, height: height))
            position += axis == .vertical ? image.height : image.width
        }
        return try XCTUnwrap(ctx.makeImage())
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(ctx.data), count: image.width * image.height * 4)
    }
    func testLongFixedEdgesAppearOnceAcrossBothAxesAndDirections() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            for direction in ScrollDirection.allCases {
                let vertical = axis == .vertical
                let page = WorkflowCorpus.texture(width: vertical ? 160 : 68000, height: vertical ? 68000 : 160, seed: 42)
                let header = WorkflowCorpus.texture(width: vertical ? 160 : 36, height: vertical ? 36 : 160, seed: 777)
                let footer = WorkflowCorpus.texture(width: vertical ? 160 : 28, height: vertical ? 28 : 160, seed: 778)
                func body(_ start: Int, _ length: Int) throws -> CGImage {
                    try XCTUnwrap(page.cropping(to: vertical ? CGRect(x: 0, y: start, width: 160, height: length) : CGRect(x: start, y: 0, width: length, height: 160)))
                }
                let model = try ScrollStitcher(axis: axis, direction: direction, fixedEdges: ScrollFixedEdges(leading: 36, trailing: 28), detectsFixedEdges: false)
                let offsets = Array(stride(from: 0, through: 65700, by: 730))
                for start in direction == .forward ? offsets : offsets.reversed() {
                    _ = try autoreleasepool { try model.append(join([header, body(start, 1000), footer], axis: axis)) }
                }
                let expected = try join([header, body(0, 66700), footer], axis: axis)
                let plan = try model.exportPlan()
                XCTAssertFalse(plan.canRenderWhole)
                for area in try plan.regions() {
                    XCTAssertEqual(try pixels(plan.render(area)), try pixels(XCTUnwrap(expected.cropping(to: area))))
                }
                try model.removeLast()
                let recapturedStart = direction == .forward ? 65400 : 300
                try model.append(join([header, body(recapturedStart, 1000), footer], axis: axis))
                let revised = try join([header, body(direction == .forward ? 0 : 300, 66400), footer], axis: axis)
                let revisedPlan = try model.exportPlan()
                for area in try revisedPlan.regions() {
                    XCTAssertEqual(try pixels(revisedPlan.render(area)), try pixels(XCTUnwrap(revised.cropping(to: area))))
                }
            }
        }
    }
    func testFixedEdgesAllAxesDirectionsPixelsPreviewUndoAndRecapture() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            for direction in ScrollDirection.allCases {
                for trailing in [0, 28] {
                    let vertical = axis == .vertical, leading = 36, bodyLength = 600 - leading - trailing
                    let page = WorkflowCorpus.texture(width: vertical ? 400 : 1600, height: vertical ? 1600 : 400, seed: 42)
                    let header = WorkflowCorpus.texture(width: vertical ? 400 : leading, height: vertical ? leading : 400, seed: 777)
                    let footer = trailing > 0 ? WorkflowCorpus.texture(width: vertical ? 400 : trailing, height: vertical ? trailing : 400, seed: 778) : nil
                    func body(_ start: Int, _ length: Int) throws -> CGImage {
                        try XCTUnwrap(page.cropping(to: vertical ? CGRect(x: 0, y: start, width: 400, height: length) : CGRect(x: start, y: 0, width: length, height: 400)))
                    }
                    func frame(_ start: Int) throws -> CGImage { try join([header, body(start, bodyLength)] + (footer.map { [$0] } ?? []), axis: axis) }
                    let starts = direction == .forward ? [100, 213, 340] : [500, 387, 260]
                    let initial = try ScrollStitcher(axis: axis, direction: direction)
                    try initial.append(frame(starts[0]))
                    XCTAssertNil(try initial.append(frame(starts[1])))
                    let edges = ScrollFixedEdges(leading: leading, trailing: trailing)
                    XCTAssertEqual(initial.suggestedFixedEdges, edges)
                    XCTAssertEqual(initial.frameCount, 1)
                    let model = try initial.reconfigured(edges: edges)
                    XCTAssertEqual(try model.append(frame(starts[1])), 113)
                    XCTAssertEqual(try model.append(frame(starts[2])), 127)
                    let expected = try join([header, body(starts.min()!, bodyLength + 240)] + (footer.map { [$0] } ?? []), axis: axis)
                    XCTAssertEqual(try pixels(model.render()), try pixels(expected))
                    let plan = try model.exportPlan()
                    for area in try plan.regions(edge: 256) {
                        XCTAssertEqual(try pixels(plan.render(area)), try pixels(XCTUnwrap(expected.cropping(to: area))))
                    }
                    XCTAssertEqual(model.preview.tiles.reduce(0) { $0 + (vertical ? $1.sourceHeight : $1.sourceWidth) }, 840)
                    XCTAssertEqual(model.preview.tiles.first?.id, -1)
                    if trailing > 0 { XCTAssertEqual(model.preview.tiles.last?.id, -2) }
                    XCTAssertEqual(try model.removeLast(), 127)
                    let changed = direction == .forward ? 320 : 280
                    XCTAssertEqual(try model.append(frame(changed)), 107)
                    let recaptured = try join([header, body(min(starts[0], changed), bodyLength + 220)] + (footer.map { [$0] } ?? []), axis: axis)
                    XCTAssertEqual(try pixels(model.render()), try pixels(recaptured))
                }
            }
        }
    }
    func testBlankRepeatedAndCornerOverlayDoNotBecomeFixedWholeEdges() throws {
        let image = WorkflowCorpus.texture(width: 400, height: 600, seed: 42)
        XCTAssertEqual(ScrollFixedEdgeDetector.detect(previous: image, next: image, axis: .vertical, offset: 0), .none)
        let page = WorkflowCorpus.texture(width: 400, height: 1000, seed: 42)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 600)))
        let next = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 400, height: 600)))
        XCTAssertEqual(ScrollFixedEdgeDetector.detect(previous: first, next: next, axis: .vertical, offset: 113), .none)
        func overlay(_ image: CGImage, blank: Bool = false) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if blank { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600)) }
            else {
                context.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 600))
                context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 560, width: 40, height: 40))
            }
            return try XCTUnwrap(context.makeImage())
        }
        let blank = try overlay(first, blank: true)
        XCTAssertEqual(ScrollFixedEdgeDetector.detect(previous: blank, next: blank, axis: .vertical, offset: 113), .none)
        XCTAssertEqual(ScrollFixedEdgeDetector.detect(previous: try overlay(first), next: try overlay(next), axis: .vertical, offset: 113), .none)
    }
    func testChangedFixedEdgeAndFailedWritesPreserveAcceptedPixels() throws {
        let page = WorkflowCorpus.texture(width: 400, height: 1400, seed: 42)
        let bar = WorkflowCorpus.texture(width: 400, height: 36, seed: 777)
        func frame(_ start: Int, _ leading: Int = 36) throws -> CGImage {
            let header = leading == 36 ? bar : WorkflowCorpus.texture(width: 400, height: leading, seed: 888)
            return try join([header, XCTUnwrap(page.cropping(to: CGRect(x: 0, y: start, width: 400, height: 600 - leading)))], axis: .vertical)
        }
        let model = try ScrollStitcher(fixedEdges: ScrollFixedEdges(leading: 36), detectsFixedEdges: false)
        try model.append(frame(100)); try model.append(frame(213))
        let accepted = try pixels(model.render())
        XCTAssertThrowsError(try model.append(frame(320, 42)))
        XCTAssertEqual(try pixels(model.render()), accepted)
        try FileManager.default.createDirectory(at: model.directory.appendingPathComponent("tile-2.png"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try model.append(frame(340)))
        XCTAssertEqual(model.frameCount, 2)
        XCTAssertEqual(try pixels(model.render()), accepted)
        let plain = try ScrollStitcher(); try plain.append(frame(100))
        let before = try pixels(plain.render())
        try Data("invalid".utf8).write(to: plain.directory.appendingPathComponent("frame-0.png"))
        XCTAssertThrowsError(try plain.reconfigured(edges: ScrollFixedEdges(leading: 36)))
        XCTAssertEqual(try pixels(plain.render()), before)
    }
    func testRepeatedHeadlinesAreOnlySuggestedAndNeverAutomaticallyRemoved() throws {
        let raw = WorkflowCorpus.texture(width: 400, height: 1400, seed: 42)
        let headline = WorkflowCorpus.texture(width: 400, height: 36, seed: 777)
        func rawSlice(_ start: Int, _ length: Int) throws -> CGImage {
            try XCTUnwrap(raw.cropping(to: CGRect(x: 0, y: start, width: 400, height: length)))
        }
        let page = try join([rawSlice(0, 100), headline, rawSlice(136, 77), headline, rawSlice(249, 1151)], axis: .vertical)
        func frame(_ start: Int) throws -> CGImage {
            try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: start, width: 400, height: 600)))
        }
        let model = try ScrollStitcher()
        try model.append(frame(100))
        XCTAssertNil(try model.append(frame(213)))
        XCTAssertEqual(model.frameCount, 1)
        XCTAssertEqual(try pixels(model.render()), try pixels(frame(100)))
        XCTAssertEqual(try model.append(frame(250)), 150)
        XCTAssertNil(model.suggestedFixedEdges)
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 100, width: 400, height: 750)))
        XCTAssertEqual(try pixels(model.render()), try pixels(expected))
    }
}
