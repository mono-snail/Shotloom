import XCTest
import AppKit
@testable import DeskCapture

final class ImageComparisonTests: XCTestCase {
    func testActualTaskCancellationAtCommitBoundaryPreservesExistingFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("keep.png"), bytes = Data("keep".utf8), source = try image(.blue)
        try bytes.write(to: output)
        let worker = Task.detached {
            try ImageComparison.exportPNG(source, to: output, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { try await worker.value; XCTFail("Cancelled export committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
    private func image(_ color: NSColor, width: Int = 80, height: Int = 60) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor); context.fill(.init(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-comparison-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    func testIdenticalImagesHaveZeroDifferenceAndStableHashes() throws {
        let source = WorkflowCorpus.texture(width: 80, height: 60, seed: 42)
        var settings = ImageComparisonSettings(); settings.mode = .difference
        let result = try ImageComparison.render(before: source, after: source, settings: settings)
        XCTAssertEqual(result.report.changedPixels, 0); XCTAssertEqual(result.report.regionCount, 0)
        XCTAssertEqual(result.report.alignedBeforeSHA256, result.report.alignedAfterSHA256)
        XCTAssertEqual(CapturePixelColor.hex(result.image, at: .init(x: 20, y: 20)), "#000000")
    }
    func testWipeEndpointsBlendAndSideBySideContainExpectedPixels() throws {
        let before = try image(.red), after = try image(.blue)
        var settings = ImageComparisonSettings(); settings.split = 1
        let a = try ImageComparison.render(before: before, after: after, settings: settings)
        XCTAssertEqual(CapturePixelColor.hex(a.image, at: .init(x: 20, y: 20)), "#FF0000")
        settings.split = 0
        let b = try ImageComparison.render(before: before, after: after, settings: settings)
        XCTAssertEqual(CapturePixelColor.hex(b.image, at: .init(x: 20, y: 20)), "#0000FF")
        settings.mode = .blend; settings.opacity = 0
        XCTAssertEqual(CapturePixelColor.hex(try ImageComparison.render(before: before, after: after, settings: settings).image, at: .init(x: 20, y: 20)), "#FF0000")
        settings.mode = .sideBySide
        let side = try ImageComparison.render(before: before, after: after, settings: settings)
        XCTAssertEqual(side.image.width, 160); XCTAssertEqual(side.image.height, 60)
        XCTAssertEqual(CapturePixelColor.hex(side.image, at: .init(x: 100, y: 20)), "#0000FF")
        XCTAssertEqual(side.report.changedPixels, 4800)
    }
    func testDifferentDimensionsPadToCommonCanvasAndReportCanReplay() throws {
        let a = try image(.black, width: 100, height: 60), b = try image(.black, width: 80, height: 60)
        var settings = ImageComparisonSettings(); settings.offsetX = 3; settings.opacity = 0.3
        let measured = try ImageComparison.render(before: a, after: b, settings: settings)
        XCTAssertEqual(measured.report.width, 100); XCTAssertEqual(measured.report.changedPixels, 1200)
        let decoded = try ImageComparisonReport.decode(JSONEncoder().encode(measured.report))
        let replay = try ImageComparison.render(before: a, after: b, settings: decoded.settings)
        XCTAssertEqual(replay.report.alignedAfterSHA256, measured.report.alignedAfterSHA256)
        XCTAssertEqual(decoded.settings, settings)
    }
    func testDifferenceRegionCoversChangedPixels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(.init(x: 0, y: 0, width: 100, height: 80))
        let before = try XCTUnwrap(context.makeImage())
        context.setFillColor(NSColor.black.cgColor); context.fill(.init(x: 40, y: 32, width: 8, height: 8))
        let after = try XCTUnwrap(context.makeImage())
        let result = try ImageComparison.render(before: before, after: after, settings: .init())
        XCTAssertEqual(result.report.changedPixels, 64)
        XCTAssertEqual(result.report.regionCount, 1)
        XCTAssertTrue(result.regions[0].contains(CGPoint(x: 44, y: 36)))
    }
    func testFailedCommitPreservesExistingDestinationAndCleansTemporaryFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("keep.png"), bytes = Data("existing destination".utf8)
        try bytes.write(to: output)
        XCTAssertThrowsError(try ImageComparison.exportPNG(image(.red), to: output, beforeCommit: { throw CancellationError() }))
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["keep.png"])
    }
    func testInvalidSettingsAndFutureRecordAreRejected() throws {
        var settings = ImageComparisonSettings(); settings.scale = .nan
        XCTAssertThrowsError(try settings.validate())
        XCTAssertThrowsError(try ImageComparisonReport.decode(Data("{}".utf8)))
        settings.scale = 1; settings.threshold = 256; XCTAssertThrowsError(try settings.validate())
    }
}
