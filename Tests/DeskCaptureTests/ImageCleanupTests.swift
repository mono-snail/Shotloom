import XCTest
import AppKit
@testable import DeskCapture

final class ImageCleanupTests: XCTestCase {
    private func pixels(width: Int = 12, height: Int = 10) throws -> CGImage {
        // Distinct rows and columns expose inversion, resampling and off-by-one errors.
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            data[i] = UInt8(x * 15); data[i + 1] = UInt8(y * 20); data[i + 2] = UInt8(x + y)
        } }
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    func testCombinedStripDeletionPreservesEveryRemainingPixelInOrder() throws {
        let source = try pixels()
        let strips = [ImageStrip(axis: .rows, start: 2, end: 4), ImageStrip(axis: .rows, start: 6, end: 8),
                      ImageStrip(axis: .columns, start: 3, end: 6), ImageStrip(axis: .columns, start: 9, end: 10)]
        let result = try CaptureImageCleanup.shorten(source, strips: strips)
        let xs = [0, 1, 2, 6, 7, 8, 10, 11], ys = [0, 1, 4, 5, 8, 9]
        XCTAssertEqual(result.width, xs.count); XCTAssertEqual(result.height, ys.count)
        for (y, sy) in ys.enumerated() { for (x, sx) in xs.enumerated() {
            XCTAssertEqual(CapturePixelColor.sample(result, at: CGPoint(x: x, y: y)),
                           CapturePixelColor.sample(source, at: CGPoint(x: sx, y: sy)))
        } }
    }
    func testCropAndStripsUseSourcePixelsRegardlessOfOperationOrder() throws {
        let source = try pixels()
        let crop = CGRect(x: 2, y: 1, width: 8, height: 8)
        let plan = ImageCleanupPlan(crop: crop, strips: [
            ImageStrip(axis: .rows, start: 0, end: 3), // intersects the top of the crop
            ImageStrip(axis: .rows, start: 5, end: 6),
            ImageStrip(axis: .columns, start: 0, end: 4), // intersects its left edge
            ImageStrip(axis: .columns, start: 8, end: 12)
        ])
        let result = try CaptureImageCleanup.render(source, plan: plan)
        let xs = [4, 5, 6, 7], ys = [3, 4, 6, 7, 8]
        XCTAssertEqual(result.width, xs.count); XCTAssertEqual(result.height, ys.count)
        for (y, sy) in ys.enumerated() { for (x, sx) in xs.enumerated() {
            XCTAssertEqual(CapturePixelColor.sample(result, at: CGPoint(x: x, y: y)),
                           CapturePixelColor.sample(source, at: CGPoint(x: sx, y: sy)))
        } }
        // Replaying a different crop from the same source must not inherit a
        // cropped bitmap, resampling or deleted rows from a previous preview.
        let reset = try CaptureImageCleanup.render(source, plan: ImageCleanupPlan())
        XCTAssertEqual(reset.width, source.width); XCTAssertEqual(reset.height, source.height)
        XCTAssertEqual(CapturePixelColor.sample(reset, at: .zero), CapturePixelColor.sample(source, at: .zero))
    }
    func testCropRejectsOutsideBoundsFractionalAndEmptyOutputWithoutChangingSource() throws {
        let source = try pixels()
        for rect in [CGRect(x: -1, y: 0, width: 8, height: 8), CGRect(x: 2, y: 1, width: 12, height: 9),
                     CGRect(x: 1.5, y: 2, width: 6, height: 6), CGRect(x: 0, y: 0, width: 0, height: 5)] {
            XCTAssertThrowsError(try CaptureImageCleanup.render(source, plan: ImageCleanupPlan(crop: rect)))
        }
        XCTAssertThrowsError(try CaptureImageCleanup.render(source,
            plan: ImageCleanupPlan(crop: CGRect(x: 2, y: 2, width: 6, height: 6),
                                   strips: [ImageStrip(axis: .rows, start: 1, end: 9)])))
        XCTAssertEqual(source.width, 12); XCTAssertEqual(source.height, 10)
    }
    func testOverlapsAdjacentRangesAndEdgesDeleteOnlyOnce() throws {
        let source = try pixels()
        let strips = [ImageStrip(axis: .rows, start: 0, end: 2), ImageStrip(axis: .rows, start: 1, end: 4),
                      ImageStrip(axis: .rows, start: 4, end: 6), ImageStrip(axis: .rows, start: 8, end: 10)]
        let result = try CaptureImageCleanup.shorten(source, strips: strips.reversed())
        XCTAssertEqual(result.height, 2)
        XCTAssertEqual(CapturePixelColor.sample(result, at: .zero), CapturePixelColor.sample(source, at: CGPoint(x: 0, y: 6)))
    }
    func testRejectsInvalidOrCompleteDeletionAndOverCapacity() throws {
        let source = try pixels()
        for strip in [ImageStrip(axis: .rows, start: 0, end: 10), ImageStrip(axis: .rows, start: -1, end: 2),
                      ImageStrip(axis: .columns, start: 2, end: 13), ImageStrip(axis: .rows, start: 4, end: 4)] {
            XCTAssertThrowsError(try CaptureImageCleanup.shorten(source, strips: [strip]))
        }
        XCTAssertThrowsError(try CaptureImageCleanup.shorten(source, strips: Array(repeating: ImageStrip(axis: .rows, start: 1, end: 2), count: 101)))
    }
    private func bordered(transparent: Bool = false, ambiguous: Bool = false) throws -> CGImage {
        var data = [UInt8](repeating: transparent ? 0 : 255, count: 20 * 16 * 4)
        for y in 3..<10 { for x in 4..<15 {
            let i = (y * 20 + x) * 4
            data[i] = 180; data[i + 1] = 20; data[i + 2] = 60; data[i + 3] = 255
        } }
        if ambiguous { data[(20 - 1) * 4] = 0 }
        return try XCTUnwrap(CGImage(width: 20, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 80,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    func testTrimOpaqueAndTransparentPaddingKeepsExactAsymmetricContent() throws {
        for transparent in [false, true] {
            let source = try bordered(transparent: transparent), result = try CaptureImageCleanup.trim(source)
            XCTAssertEqual(result.width, 11); XCTAssertEqual(result.height, 7)
            for y in 0..<7 { for x in 0..<11 {
                XCTAssertEqual(CapturePixelColor.sample(result, at: CGPoint(x: x, y: y)),
                               CapturePixelColor.sample(source, at: CGPoint(x: x + 4, y: y + 3)))
            } }
        }
    }
    func testTrimRefusesAmbiguousEdgesOrEmptyImage() throws {
        XCTAssertThrowsError(try CaptureImageCleanup.trim(bordered(ambiguous: true)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        XCTAssertThrowsError(try CaptureImageCleanup.trim(try XCTUnwrap(context.makeImage())))
        XCTAssertThrowsError(try CaptureImageCleanup.trim(bordered(), tolerance: 65))
    }
    func testCancelledWorkerDoesNotReturnAnImage() async throws {
        let source = try pixels()
        let worker = Task.detached {
            try await Task.sleep(for: .milliseconds(50))
            return try CaptureImageCleanup.render(source, plan: ImageCleanupPlan(trim: true))
        }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled worker returned output") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor
    func testLocalForegroundMaskHasTransparentBackgroundAndOpaqueSubject() async throws {
        let source = try QualityDiagnostics.cleanupFixture()
        let result = try await Task.detached { try CaptureImageCleanup.foreground(source) }.value
        XCTAssertEqual(result.width, source.width); XCTAssertEqual(result.height, source.height)
        XCTAssertEqual(QualityDiagnostics.alpha(result, at: .zero), 0)
        XCTAssertGreaterThan(QualityDiagnostics.alpha(result, at: CGPoint(x: 400, y: 300)), 200)
    }
    @MainActor
    func testEditsAndCloseRejectStaleProcessingResults() async throws {
        let model = ImageCleanupModel(source: try pixels())
        model.update(ImageCleanupPlan(strips: [ImageStrip(axis: .rows, start: 2, end: 4)]))
        model.update(ImageCleanupPlan(strips: [ImageStrip(axis: .columns, start: 2, end: 7)]))
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.result?.width, 7); XCTAssertEqual(model.result?.height, 10); XCTAssertNil(model.error)
        model.update(ImageCleanupPlan(trim: true))
        model.cancel()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.result); XCTAssertNil(model.error); XCTAssertFalse(model.busy)
    }
    @MainActor
    func testProductionCleanupEntryCreatesResizableWindowAndNativeCloseCancelsWork() async throws {
        _ = NSApplication.shared
        let app = AppCoordinator(), old = Set(NSApp.windows.map(\.windowNumber))
        app.showCleanup(try pixels())
        let window = try XCTUnwrap(NSApp.windows.first { !old.contains($0.windowNumber) && $0.title == L10n.text("裁剪与清理 — DeskCapture") })
        defer { window.close() }
        XCTAssertTrue(window.isVisible); XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, CGSize(width: 820, height: 560))
        let model = try XCTUnwrap((window as? ImageCleanupWindow)?.model)
        model.update(ImageCleanupPlan(trim: true))
        window.performClose(nil); XCTAssertFalse(window.isVisible)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.busy); XCTAssertNil(model.result)
    }
    @MainActor
    func testEditingDuringPreparationDoesNotOpenOutdatedCleanupWindow() async throws {
        _ = NSApplication.shared
        let app = AppCoordinator(), document = AnnotationDocument(image: try pixels())
        let parent = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.orderFront(nil)
        defer { parent.close() }
        let old = Set(NSApp.windows.map(\.windowNumber))
        app.showCleanup(document, parent: parent)
        document.add(document.makeMark(tool: .rectangle, points: [.zero, CGPoint(x: 0.5, y: 0.5)]))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(NSApp.windows.contains { !old.contains($0.windowNumber) && $0.title == L10n.text("裁剪与清理 — DeskCapture") })
        withExtendedLifetime(app) {}
    }
}
