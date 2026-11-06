import XCTest
import AppKit
@testable import DeskCapture

final class ScrollTests: XCTestCase {
    func testSingleCoarseCandidateCannotBypassDenseRepeatedTextValidation() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-single-alias-before"), next = try image("textedit-single-alias-after-158")
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 158)
        XCTAssertEqual(ScrollMatcher.match(previous: next, next: first, direction: .reverse)?.offset, 158)
    }

    func testDenseUniqueRowsProposeOffsetMissingFromCoarseShortlist() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-missing-proposal-before"), next = try image("textedit-missing-proposal-after-158")
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 158)
        XCTAssertEqual(ScrollMatcher.match(previous: next, next: first, direction: .reverse)?.offset, 158)
    }

    func testRealGeneratedTextEditRowsResolveAliasedLineShapes() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-sparse-before"), next = try image("textedit-sparse-after-158")
        // Independent AX first-glyph coordinates moved 79 points at 2x.
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 158)
        XCTAssertEqual(ScrollMatcher.match(previous: next, next: first, direction: .reverse)?.offset, 158)
    }

    func testRealGeneratedMixedChineseEnglishRowsKeepSmallUniqueNumbers() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-mixed-before"), next = try image("textedit-mixed-after-158")
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 158)
        XCTAssertEqual(ScrollMatcher.match(previous: next, next: first, direction: .reverse)?.offset, 158)
    }
    func testRealMixedTextEdgesAreNotDilutedByBlankBackground() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-mixed-large-before"), next = try image("textedit-mixed-large-after-158")
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 158)
        XCTAssertEqual(ScrollMatcher.match(previous: next, next: first, direction: .reverse)?.offset, 158)
    }
    func testRealParagraphShortRepeatingOverlapCannotBeatDistinctiveRows() throws {
        func image(_ name: String) throws -> CGImage {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let first = try image("textedit-paragraph-before"), next = try image("textedit-paragraph-after-158")
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 158)
        XCTAssertEqual(ScrollMatcher.match(previous: next, next: first, direction: .reverse)?.offset, 158)
    }
    func testDenseRefinementStillRejectsRepeatedTextWithoutUniqueRows() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "textedit-sparse-before", withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let row = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 38, width: image.width, height: 38)))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: 1216, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: 1216, by: 38) { context.draw(row, in: CGRect(x: 0, y: y, width: image.width, height: 38)) }
        let page = try XCTUnwrap(context.makeImage())
        let before = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 740)))
        let after = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 6, width: image.width, height: 740)))
        XCTAssertNil(ScrollMatcher.match(previous: before, next: after))
    }
    func testMatchesExactOffsetAndRendersEveryRowInOrder() throws {
        let page = fixture(width: 200, height: 900)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 400)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 200, height: 400)))
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: second)?.offset, 113)
        let stitcher = try ScrollStitcher()
        XCTAssertEqual(try stitcher.append(first), 400)
        XCTAssertEqual(try stitcher.append(second), 113)
        let result = try stitcher.render()
        XCTAssertEqual(result.height, 513)
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 513)))
        XCTAssertEqual(ScrollMatcher.grayscale(result), ScrollMatcher.grayscale(expected))
    }
    func testTallCaptureFindsNonRoundPixelOffset() throws {
        let page = fixture(width: 120, height: 7200)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 3200)))
        let next = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 1137, width: 120, height: 3200)))
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 1137)
    }
    func testFixedHeaderDoesNotOverrideScrollingContent() throws {
        let page = fixture(width: 120, height: 5200)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 3200)))
        let shifted = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 1137, width: 120, height: 3200)))
        let header = try XCTUnwrap(first.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 650)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 3200, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(shifted, in: CGRect(x: 0, y: 0, width: 120, height: 3200))
        context.draw(header, in: CGRect(x: 0, y: 2550, width: 120, height: 650))
        let next = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 1137)
    }
    func testHorizontalScrollMatchesRendersPreviewsAndCanUndo() throws {
        let page = fixture(width: 900, height: 200)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 200)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 113, y: 0, width: 400, height: 200)))
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: second, axis: .horizontal)?.offset, 113)
        let stitcher = try ScrollStitcher(axis: .horizontal)
        XCTAssertEqual(try stitcher.append(first), 400)
        XCTAssertEqual(try stitcher.append(second), 113)
        XCTAssertEqual(stitcher.preview.width, 513)
        XCTAssertEqual(stitcher.preview.height, 200)
        XCTAssertEqual(stitcher.preview.tiles.map(\.sourceWidth), [400, 113])
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 513, height: 200)))
        XCTAssertEqual(ScrollMatcher.grayscale(try stitcher.render()), ScrollMatcher.grayscale(expected))
        XCTAssertEqual(try stitcher.removeLast(), 113)
        XCTAssertEqual(stitcher.preview.width, 400)
        XCTAssertEqual(try stitcher.append(second), 113)
    }
    @MainActor
    func testHorizontalPreviewFollowsRightEdge() throws {
        let page = fixture(width: 900, height: 200)
        let stitcher = try ScrollStitcher(axis: .horizontal)
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 200))))
        let scroll = ScrollPreviewScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scroll.documentView = ScrollPreviewCanvas()
        scroll.update(preview: stitcher.preview, overview: false, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.maxX, scroll.documentView!.frame.width, accuracy: 1)
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 113, y: 0, width: 400, height: 200))))
        scroll.update(preview: stitcher.preview, overview: false, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.maxX, scroll.documentView!.frame.width, accuracy: 1)
    }
    func testIdenticalFramesDoNotDuplicateContent() throws {
        let image = fixture(width: 200, height: 300)
        let stitcher = try ScrollStitcher(); try stitcher.append(image)
        XCTAssertEqual(try stitcher.append(image), 0)
        XCTAssertEqual(stitcher.totalHeight, 300)
        XCTAssertEqual(stitcher.frameCount, 1)
    }
    func testUnrelatedFramesAreRejectedInsteadOfInventingSeam() throws {
        let a = fixture(width: 200, height: 400, seed: 133)
        let b = fixture(width: 200, height: 400, seed: 987)
        XCTAssertNil(ScrollMatcher.match(previous: a, next: b))
    }
    func testLocalVideoDoesNotPreventVerticalOrHorizontalMatching() throws {
        let page = fixture(width: 900, height: 900)
        for axis in [ScrollAxis.vertical, .horizontal] {
            let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 400)))
            let shifted = try XCTUnwrap(page.cropping(to: CGRect(x: axis == .horizontal ? 113 : 0,
                                                               y: axis == .vertical ? 113 : 0, width: 400, height: 400)))
            // A changing video occupying one quarter of the viewport and
            // crossing all scanlines defeats the old whole-row fingerprints.
            let next = try replacing(shifted, rect: axis == .vertical
                ? CGRect(x: 150, y: 0, width: 100, height: 400)
                : CGRect(x: 0, y: 150, width: 400, height: 100))
            XCTAssertEqual(ScrollMatcher.match(previous: first, next: next, axis: axis)?.offset, 113)
            let stitcher = try ScrollStitcher(axis: axis)
            try stitcher.append(first)
            XCTAssertEqual(try stitcher.append(next), 113)
            XCTAssertEqual(stitcher.frameCount, 2)
            XCTAssertEqual(axis == .vertical ? stitcher.totalHeight : stitcher.totalWidth, 513)
        }
    }
    func testTallDynamicViewportFindsExactSeam() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            let width = axis == .vertical ? 1200 : 5200
            let height = axis == .vertical ? 5200 : 1200
            let page = fixture(width: width, height: height)
            let viewport = CGSize(width: axis == .vertical ? 1200 : 3200,
                                  height: axis == .vertical ? 3200 : 1200)
            let first = try XCTUnwrap(page.cropping(to: CGRect(origin: .zero, size: viewport)))
            let shifted = try XCTUnwrap(page.cropping(to: CGRect(
                x: axis == .horizontal ? 1137 : 0, y: axis == .vertical ? 1137 : 0,
                width: viewport.width, height: viewport.height)))
            let next = try replacing(shifted, rect: axis == .vertical
                ? CGRect(x: 900, y: 0, width: 300, height: 3200)
                : CGRect(x: 0, y: 900, width: 3200, height: 300))
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3 {
                XCTAssertEqual(ScrollMatcher.match(previous: first, next: next, axis: axis)?.offset, 1137)
            }
            print("SCROLL_BENCH axis=\(axis) meanSeconds=\((ProcessInfo.processInfo.systemUptime - start) / 3)")
        }
    }
    func testCancelledWorkerDoesNotCommitAndCanRetry() async throws {
        let stitcher = try ScrollStitcher(), worker = ScrollCaptureWorker(stitcher)
        let image = fixture(width: 400, height: 600)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.append(image)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled append must not commit") }
        catch is CancellationError {}
        XCTAssertEqual(stitcher.frameCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stitcher.directory.path).isEmpty)
        let update = try await worker.append(image)
        XCTAssertEqual(update.frames, 1); XCTAssertEqual(update.preview.height, 600)
        let cancelledRender = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.render()
        }
        do { _ = try await cancelledRender.value; XCTFail("Cancelled render must fail") }
        catch is CancellationError {}
        let rendered = try await worker.render()
        XCTAssertEqual(rendered.height, 600)
    }
    @MainActor
    func testUndoThroughModelCanExportAndCancelCannotRestoreOldPreview() async throws {
        for cancelDuringUndo in [false, true] {
            let page = fixture(width: 400, height: 1200), stitcher = try ScrollStitcher()
            try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 600))))
            try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 137, width: 400, height: 600))))
            let model = ScrollCapture(stitcher: stitcher)
            let undo = Task { await model.removeLastSegment() }
            if cancelDuringUndo {
                await Task.yield()
                await model.cancel()
                await undo.value
                XCTAssertFalse(model.active); XCTAssertFalse(model.processingSegment)
                XCTAssertTrue(model.preview.tiles.isEmpty)
            } else {
                await undo.value
                XCTAssertEqual(model.frames, 1); XCTAssertEqual(model.preview.height, 600)
                XCTAssertFalse(model.processingSegment); XCTAssertTrue(model.paused)
                var result: CGImage?
                model.onFinish = { image, _ in result = image }
                await model.finish()
                XCTAssertEqual(result.map { ScrollMatcher.grayscale($0) },
                               ScrollMatcher.grayscale(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 600)))))
                XCTAssertFalse(model.active)
            }
        }
    }
    func testVideoChangesWithoutScrollingDoNotAppendContent() throws {
        let first = fixture(width: 400, height: 400)
        let next = try replacing(first, rect: CGRect(x: 150, y: 0, width: 100, height: 400))
        let stitcher = try ScrollStitcher()
        try stitcher.append(first)
        XCTAssertEqual(try stitcher.append(next), 0)
        XCTAssertEqual(stitcher.frameCount, 1)
    }
    func testMostlyChangingContentIsRejected() throws {
        let page = fixture(width: 400, height: 900)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 400)))
        let shifted = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 400, height: 400)))
        let next = try replacing(shifted, rect: CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertNil(ScrollMatcher.match(previous: first, next: next))
    }
    func testWideBlankMarginsDoNotOutvoteScrollingContent() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 900,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 900))
        context.draw(fixture(width: 120, height: 900), in: CGRect(x: 140, y: 0, width: 120, height: 900))
        let page = try XCTUnwrap(context.makeImage())
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 400)))
        let next = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 400, height: 400)))
        XCTAssertEqual(ScrollMatcher.match(previous: first, next: next)?.offset, 113)
    }
    func testPreviewContainsOnlyAcceptedStripsInExportOrder() throws {
        let page = fixture(width: 200, height: 900)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 400)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 200, height: 400)))
        let stitcher = try ScrollStitcher()
        try stitcher.append(first); try stitcher.append(second)
        let preview = stitcher.preview
        XCTAssertEqual(preview.width, 200); XCTAssertEqual(preview.height, 513)
        XCTAssertEqual(preview.tiles.map(\.sourceHeight), [400, 113])
        XCTAssertEqual(preview.lastIncrement, 113)
        XCTAssertEqual(ScrollMatcher.grayscale(preview.tiles[0].image), ScrollMatcher.grayscale(first))
        let expectedStrip = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 400, width: 200, height: 113)))
        XCTAssertEqual(ScrollMatcher.grayscale(preview.tiles[1].image), ScrollMatcher.grayscale(expectedStrip))
        XCTAssertEqual(try stitcher.append(second), 0)
        XCTAssertNil(try stitcher.append(fixture(width: 200, height: 400, seed: 987)))
        XCTAssertEqual(stitcher.preview.tiles.count, 2)
        XCTAssertEqual(stitcher.preview.height, 513, "Failed seams keep the last successful preview")
    }
    func testUndoLastSegmentCanRecaptureFromPriorFrame() throws {
        let page = fixture(width: 200, height: 950)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 400)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 200, height: 400)))
        let replacement = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 160, width: 200, height: 400)))
        let stitcher = try ScrollStitcher()
        try stitcher.append(first); try stitcher.append(second)
        XCTAssertTrue(stitcher.canRemoveLast)
        XCTAssertEqual(try stitcher.removeLast(), 113)
        XCTAssertEqual(stitcher.totalHeight, 400); XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertEqual(stitcher.preview.tiles.count, 1)
        XCTAssertEqual(try stitcher.append(replacement), 160)
        XCTAssertEqual(stitcher.totalHeight, 560)
        XCTAssertEqual(ScrollMatcher.grayscale(try stitcher.render()),
                       ScrollMatcher.grayscale(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 560)))))
    }
    func testPaginatedPDFExportsMultiplePages() throws {
        let image = fixture(width: 200, height: 1000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try CaptureImageExport.pdf(image, to: url)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 4)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).width, 595)
    }
    func testHorizontalPDFPaginatesColumnsAtReadableScale() throws {
        let image = fixture(width: 1000, height: 200)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try CaptureImageExport.pdf(image, to: url, axis: .horizontal)
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 4)
        XCTAssertEqual(document.page(at: 1)?.getBoxRect(.mediaBox).width, 842)
    }
    func testLivePreviewUsesSmallImagesWhileExportKeepsOriginalResolution() throws {
        let original = fixture(width: 1600, height: 1000)
        let stitcher = try ScrollStitcher(); try stitcher.append(original)
        let thumbnail = try XCTUnwrap(stitcher.preview.tiles.first?.image)
        XCTAssertEqual(thumbnail.width, 240); XCTAssertEqual(thumbnail.height, 150)
        let export = try stitcher.render()
        XCTAssertEqual(export.width, 1600); XCTAssertEqual(export.height, 1000)
        XCTAssertEqual(ScrollMatcher.grayscale(export), ScrollMatcher.grayscale(original))
    }
    @MainActor
    func testPreviewFollowsTailCanInspectEarlierContentAndFitOverview() throws {
        let page = fixture(width: 200, height: 900)
        let stitcher = try ScrollStitcher()
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 400))))
        let scroll = ScrollPreviewScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
        scroll.documentView = ScrollPreviewCanvas()
        scroll.update(preview: stitcher.preview, overview: false, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.frame.height, accuracy: 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 70))
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 200, height: 400))))
        scroll.update(preview: stitcher.preview, overview: false, followsTail: false)
        XCTAssertEqual(scroll.contentView.bounds.minY, 70, accuracy: 1, "Review position must survive new strips")
        scroll.update(preview: stitcher.preview, overview: false, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.frame.height, accuracy: 1)
        scroll.update(preview: stitcher.preview, overview: true, followsTail: true)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        XCTAssertEqual(scroll.documentView!.frame.height, scroll.contentView.bounds.height, accuracy: 1)
    }
    func testPreviewPanelAvoidsSelectionAndStaysInsideScreen() {
        let screen = CGRect(x: -1920, y: 40, width: 1920, height: 1040)
        for selection in [CGRect(x: -1800, y: 200, width: 700, height: 600), CGRect(x: -750, y: 200, width: 700, height: 600)] {
            let panel = ScrollPreviewGeometry.panelFrame(selection: selection, visibleFrame: screen, size: CGSize(width: 288, height: 432))
            XCTAssertTrue(screen.contains(panel)); XCTAssertTrue(panel.intersection(selection).isNull)
        }
        let fallback = ScrollPreviewGeometry.panelFrame(selection: screen, visibleFrame: screen, size: CGSize(width: 288, height: 432))
        XCTAssertTrue(screen.contains(fallback))
    }
    @MainActor
    func testDeniedAutomationKeepsCapturedContentAndCanEnableAfterAuthorization() throws {
        let stitcher = try ScrollStitcher(); try stitcher.append(fixture(width: 200, height: 300))
        var trusted = false, permissionRequests = 0
        let model = ScrollCapture(stitcher: stitcher, isAutomationTrusted: { trusted }, requestAutomationPermission: { permissionRequests += 1 })
        XCTAssertFalse(model.setAutomatic(true))
        XCTAssertFalse(model.automatic); XCTAssertTrue(model.active); XCTAssertTrue(model.paused)
        XCTAssertTrue(model.needsAutomationPermission); XCTAssertEqual(model.preview.height, 300)
        XCTAssertEqual(permissionRequests, 1)
        trusted = true
        XCTAssertTrue(model.setAutomatic(true)); XCTAssertTrue(model.automatic); XCTAssertFalse(model.needsAutomationPermission)
        XCTAssertEqual(model.preview.height, 300)
        trusted = false
        XCTAssertFalse(model.setAutomatic(true, requestPermission: false)); XCTAssertFalse(model.automatic)
        XCTAssertEqual(permissionRequests, 1, "Revocation must not repeatedly open permission prompts")
        XCTAssertTrue(model.setAutomatic(false)); XCTAssertFalse(model.needsAutomationPermission)
    }
    @MainActor
    func testPermissionPresentationPrecedesSystemPromptAndResumeRestoresManualCapture() throws {
        let stitcher = try ScrollStitcher(); try stitcher.append(fixture(width: 200, height: 300))
        var events: [String] = []
        let model = ScrollCapture(stitcher: stitcher, isAutomationTrusted: { false },
                                  requestAutomationPermission: { events.append("system prompt") })
        model.onAutomationPermissionPresentation = { presenting in
            events.append(presenting ? "lower preview" : "restore preview")
        }
        XCTAssertFalse(model.setAutomatic(true))
        XCTAssertEqual(events, ["lower preview", "system prompt"])
        XCTAssertTrue(model.presentingAutomationPermission); XCTAssertTrue(model.paused)
        model.togglePause()
        XCTAssertEqual(events.last, "restore preview")
        XCTAssertFalse(model.presentingAutomationPermission); XCTAssertFalse(model.paused)
        XCTAssertFalse(model.automatic); XCTAssertEqual(model.preview.height, 300)
    }
    @MainActor
    func testSavePickerCancellationRestoresRunningOrPausedSessionAndBlocksOtherFinishes() async throws {
        let stitcher = try ScrollStitcher(); try stitcher.append(fixture(width: 200, height: 300))
        let model = ScrollCapture(stitcher: stitcher, isAutomationTrusted: { true })
        XCTAssertTrue(model.setAutomatic(true))
        var completed = false
        model.onFinish = { _, _ in completed = true }
        XCTAssertTrue(model.beginFileSelection()); XCTAssertTrue(model.paused); XCTAssertTrue(model.choosingFile)
        XCTAssertFalse(model.beginFileSelection()); XCTAssertFalse(model.setAutomatic(false))
        await model.finish()
        XCTAssertFalse(completed); XCTAssertTrue(model.active)
        await model.completeFileSelection(nil)
        XCTAssertFalse(model.paused); XCTAssertTrue(model.automatic); XCTAssertEqual(model.preview.height, 300)
        model.togglePause()
        XCTAssertTrue(model.beginFileSelection())
        await model.completeFileSelection(nil)
        XCTAssertTrue(model.paused, "Cancelling save must respect a session that was already paused")
    }
    @MainActor
    func testCancellingSegmentPickerRestoresRunningOrPausedCaptureWithoutExport() async throws {
        let stitcher = try ScrollStitcher()
        try stitcher.append(fixture(width: 200, height: 300))
        let model = ScrollCapture(stitcher: stitcher)
        var completed = false; model.onFinish = { _, _ in completed = true }
        XCTAssertTrue(model.beginFileSelection()); XCTAssertTrue(model.paused)
        await model.completeSegmentSelection(nil)
        XCTAssertTrue(model.active); XCTAssertFalse(model.paused); XCTAssertFalse(model.choosingFile)
        model.togglePause()
        XCTAssertTrue(model.beginFileSelection())
        await model.completeSegmentSelection(nil)
        XCTAssertTrue(model.paused); XCTAssertEqual(model.frames, 1); XCTAssertFalse(completed)
        await model.cancel()
    }
    @MainActor
    func testSavingLongImageWritesAllOriginalPixelsAndDoesNotTouchClipboard() async throws {
        let page = fixture(width: 200, height: 900)
        let stitcher = try ScrollStitcher()
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 400))))
        try stitcher.append(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 200, height: 400))))
        let model = ScrollCapture(stitcher: stitcher)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("长图 export.png")
        var completedURL: URL?
        model.onFinish = { _, output in if case .file(let savedURL) = output { completedURL = savedURL } }
        let clipboardVersion = NSPasteboard.general.changeCount
        XCTAssertTrue(model.beginFileSelection())
        await model.completeFileSelection(url)
        XCTAssertEqual(completedURL, url); XCTAssertFalse(model.active); XCTAssertFalse(model.finishing)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 513)
        XCTAssertEqual(ScrollMatcher.grayscale(image), ScrollMatcher.grayscale(try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 513)))))
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardVersion)
    }
    @MainActor
    func testFileWriteFailureKeepsPreviewAndAllowsRetry() async throws {
        let stitcher = try ScrollStitcher(); try stitcher.append(fixture(width: 200, height: 300))
        let model = ScrollCapture(stitcher: stitcher)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("retry.png")
        defer { try? FileManager.default.removeItem(at: directory) }
        var completions = 0
        model.onFinish = { _, _ in completions += 1 }
        await model.finish(output: .file(url))
        XCTAssertTrue(model.active); XCTAssertTrue(model.paused); XCTAssertFalse(model.finishing)
        XCTAssertEqual(model.preview.height, 300); XCTAssertNotNil(model.warning); XCTAssertEqual(completions, 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.finish(output: .file(url))
        XCTAssertFalse(model.active); XCTAssertEqual(completions, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor
    func testDefaultCompletionStillReturnsClipboardDestination() async throws {
        let stitcher = try ScrollStitcher(); try stitcher.append(fixture(width: 200, height: 300))
        let model = ScrollCapture(stitcher: stitcher)
        var receivedClipboard = false
        model.onFinish = { image, output in
            if case .clipboard = output { receivedClipboard = image.width == 200 && image.height == 300 }
        }
        await model.finish()
        XCTAssertTrue(receivedClipboard); XCTAssertFalse(model.active)
    }
    func testAutomationUsesSelectionCenterAndBoundsScrollStepOnAnotherDisplay() throws {
        let event = try XCTUnwrap(ScrollAutomationEvent.make(rect: CGRect(x: 300, y: 40, width: 800, height: 1000),
                                                            screenFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
                                                            desktopTop: 1080))
        XCTAssertEqual(event.location, CGPoint(x: -1220, y: 1620))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -160)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
        let small = try XCTUnwrap(ScrollAutomationEvent.make(rect: CGRect(x: 0, y: 0, width: 200, height: 60),
                                                            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), desktopTop: 1000))
        XCTAssertEqual(small.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -13, "Short selections need smaller steps to retain overlap")
        let horizontal = try XCTUnwrap(ScrollAutomationEvent.make(rect: CGRect(x: 0, y: 0, width: 200, height: 60),
                                                                  screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                                                  desktopTop: 1000, axis: .horizontal))
        XCTAssertEqual(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(horizontal.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -44)
    }
    private func replacing(_ image: CGImage, rect: CGRect) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(fixture(width: Int(rect.width), height: Int(rect.height), seed: 987), in: rect)
        return try XCTUnwrap(context.makeImage())
    }
    private func fixture(width: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1
                let value = UInt8((state >> 32) & 255)
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testFortyConsecutiveScrollSegmentsPreservePixelsAndCanUndo() throws {
        let page = fixture(width: 400, height: 7200), stitcher = try ScrollStitcher()
        for index in 0..<40 {
            let frame = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: index * 137, width: 400, height: 1200)))
            XCTAssertEqual(try stitcher.append(frame), index == 0 ? 1200 : 137)
        }
        XCTAssertEqual(stitcher.frameCount, 40); XCTAssertEqual(stitcher.totalHeight, 6543)
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 6543)))
        XCTAssertEqual(ScrollMatcher.grayscale(try stitcher.render()), ScrollMatcher.grayscale(expected))
        for _ in 0..<10 { XCTAssertEqual(try stitcher.removeLast(), 137) }
        XCTAssertEqual(stitcher.frameCount, 30); XCTAssertEqual(stitcher.totalHeight, 5173)
    }
}
