import XCTest
import AppKit
@testable import DeskCapture

final class CapabilityTests: XCTestCase {
    func testURLCommandsClampDelayAndRejectOtherSchemes() throws {
        let command = try XCTUnwrap(CaptureURLCommand(URL(string: "deskcapture://capture?mode=region&delay=999&repeat=1")!))
        if case .capture(let mode, let delay, let repeated) = command {
            XCTAssertEqual(mode, .region); XCTAssertEqual(delay, 10); XCTAssertTrue(repeated)
        } else { XCTFail("Expected a capture action") }
        XCTAssertNil(CaptureURLCommand(URL(string: "https://capture?mode=region")!))
        XCTAssertNil(CaptureURLCommand(URL(string: "deskcapture://capture?mode=unknown")!))
    }
    func testPixelColorSamplingRejectsOutsideImage() {
        let source = image(.red)
        XCTAssertEqual(CapturePixelColor.hex(source, at: CGPoint(x: 5, y: 5)), "#FF0000")
        XCTAssertNil(CapturePixelColor.hex(source, at: CGPoint(x: -1, y: 5)))
        XCTAssertNil(CapturePixelColor.hex(source, at: CGPoint(x: 40, y: 0)))
        XCTAssertNil(CapturePixelColor.sample(source, at: CGPoint(x: CGFloat.nan, y: 0)))
        let sample = CapturePixelColor.sample(source, at: CGPoint(x: 5, y: 5))
        XCTAssertEqual(sample?.rgb, "rgb(255, 0, 0)")
    }
    private func image(_ color: NSColor, width: Int = 40, height: Int = 20) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    func testRotationResizeAndLimits() throws {
        let source = image(.red)
        let rotated = try CaptureImageTransform.render(source, turns: 1)
        XCTAssertEqual(rotated.width, 20); XCTAssertEqual(rotated.height, 40)
        let scaled = try CaptureImageTransform.render(source, width: 80, height: 40)
        XCTAssertEqual(scaled.width, 80); XCTAssertEqual(scaled.height, 40)
        XCTAssertThrowsError(try CaptureImageTransform.render(source, width: 0))
        XCTAssertThrowsError(try CaptureImageTransform.render(source, width: 50_000, height: 50_000))
    }
    func testCombinationKeepsBothImagesAndGap() throws {
        let red = image(.red), blue = image(.blue)
        let vertical = try CaptureImageTransform.combine([red, blue], horizontal: false, gap: 4)
        XCTAssertEqual(vertical.width, 40); XCTAssertEqual(vertical.height, 44)
        let horizontal = try CaptureImageTransform.combine([red, blue], horizontal: true, gap: 4)
        XCTAssertEqual(horizontal.width, 84); XCTAssertEqual(horizontal.height, 20)
        let bytes = try XCTUnwrap(horizontal.dataProvider?.data) as Data
        XCTAssertGreaterThan(bytes[10 * horizontal.bytesPerRow + 10 * 4], 240)
        XCTAssertGreaterThan(bytes[10 * horizontal.bytesPerRow + 60 * 4 + 2], 240)
        XCTAssertThrowsError(try CaptureImageTransform.combine([], horizontal: false))
    }
    func testMultipleFormatsProduceReadableImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in ["png", "jpg", "tiff", "heic"] {
            let url = directory.appendingPathComponent("image.\(format)")
            try CaptureImageExport.write(image(.red), to: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(result.width, 40); XCTAssertEqual(result.height, 20)
        }
    }
    func testBackgroundLayoutsKeepSourceWhole() throws {
        let source = image(.red, width: 100, height: 50)
        for layout in BeautifyLayout.allCases {
            let rendered = try CaptureBeautifier.render(source, style: .frost, paddingPercent: 0.1, roundness: 0, layout: layout)
            XCTAssertGreaterThanOrEqual(rendered.width, source.width)
            XCTAssertGreaterThanOrEqual(rendered.height, source.height)
            if let ratio = layout.ratio { XCTAssertEqual(Double(rendered.width) / Double(rendered.height), ratio, accuracy: 0.015) }
        }
    }
    func testCursorInterpolationAndZoomReturnToRest() {
        let events = [RecordedInteraction(time: 0, x: 0, y: 0, kind: .pointer),
                      RecordedInteraction(time: 1, x: 1, y: 1, kind: .pointer)]
        XCTAssertEqual(RecordingMotion.pointer(at: 0.5, events: events)?.x, 0.5)
        XCTAssertEqual(RecordingMotion.pointer(at: 2, events: events)?.x, 1)
        let clicks = [RecordedInteraction(time: 1, x: 0.8, y: 0.6, kind: .click)]
        XCTAssertEqual(RecordingMotion.zoom(at: 0, clicks: clicks, maximum: 2).0, 1)
        XCTAssertEqual(RecordingMotion.zoom(at: 1.5, clicks: clicks, maximum: 2).0, 2)
        XCTAssertEqual(RecordingMotion.zoom(at: 4, clicks: clicks, maximum: 2).0, 1)
    }
    @MainActor
    func testLastSelectionRejectsChangedDisplayGeometry() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let valid = LastCaptureSelection(displayID: id, screenSize: screen.frame.size, rect: CGRect(x: 10, y: 10, width: 100, height: 50))
        XCTAssertNotNil(valid.selection(for: screen))
        let invalid = LastCaptureSelection(displayID: id, screenSize: .zero, rect: valid.rect)
        XCTAssertNil(invalid.selection(for: screen))
    }
}
