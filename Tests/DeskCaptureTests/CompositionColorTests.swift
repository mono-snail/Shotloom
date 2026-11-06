import XCTest
import AppKit
@testable import DeskCapture

final class CompositionColorTests: XCTestCase {
    func testAsymmetricContentAndBlankBackground() throws {
        let width = 100, height = 80
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 10..<30 { for x in 10..<30 { for c in 0..<3 { bytes[(y * width + x) * 4 + c] = 0 } } }
        let result = try SmartComposition.analyze(width: width, height: height, rgba: bytes)
        XCTAssertTrue(result.confident)
        XCTAssertEqual(result.focus.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(result.focus.y, 0.75, accuracy: 0.001)
        XCTAssertEqual(result.bounds, CGRect(x: 0.1, y: 0.625, width: 0.2, height: 0.25))
        let blank = try SmartComposition.analyze(width: 100, height: 80, rgba: [UInt8](repeating: 255, count: 32000))
        XCTAssertFalse(blank.confident); XCTAssertEqual(blank.focus, CGPoint(x: 0.5, y: 0.5))
    }
    func testCompositionNeverCutsImageAtExtremeFocusOrRatio() throws {
        for canvas in [CGSize(width: 500, height: 400), CGSize(width: 800, height: 1400), CGSize(width: 1600, height: 500)] {
            for focus in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.2, y: 0.8)] {
                let rect = try SmartComposition.placement(image: CGSize(width: 400, height: 300), canvas: canvas, focus: focus)
                XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(rect))
                XCTAssertEqual(rect.size, CGSize(width: 400, height: 300))
                XCTAssertEqual(rect.minX, floor(rect.minX)); XCTAssertEqual(rect.minY, floor(rect.minY))
            }
        }
        XCTAssertThrowsError(try SmartComposition.placement(image: .init(width: 400, height: 300), canvas: .init(width: 100, height: 100), focus: .zero))
    }
    func testOKLCHFixedPrimaryColorsAndAchromaticHue() throws {
        let red = CaptureColorAnalysis.oklch(try XCTUnwrap(CaptureColorAnalysis.parse("#FF0000")))
        XCTAssertEqual(red.lightness, 0.62795536, accuracy: 0.000001)
        XCTAssertEqual(red.chroma, 0.25768331, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(red.hue), 29.233885, accuracy: 0.0001)
        let blue = CaptureColorAnalysis.oklch(try XCTUnwrap(CaptureColorAnalysis.parse("0000FF")))
        XCTAssertEqual(blue.lightness, 0.45201372, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(blue.hue), 264.05202, accuracy: 0.0001)
        XCTAssertNil(CaptureColorAnalysis.oklch(.init(red: 128, green: 128, blue: 128)).hue)
        XCTAssertNil(CaptureColorAnalysis.parse("#FFF")); XCTAssertNil(CaptureColorAnalysis.parse("-00001"))
    }
    func testContrastUsesRelativeLuminanceAndUnroundedRatio() throws {
        let black = try XCTUnwrap(CaptureColorAnalysis.parse("000000")), white = try XCTUnwrap(CaptureColorAnalysis.parse("FFFFFF"))
        XCTAssertEqual(CaptureColorAnalysis.contrast(black, white), 21, accuracy: 0.000001)
        XCTAssertEqual(CaptureColorAnalysis.contrast(white, white), 1, accuracy: 0.000001)
        XCTAssertEqual(CaptureColorAnalysis.contrast(.init(red: 119, green: 119, blue: 119), white), 4.478089, accuracy: 0.00001)
        XCTAssertLessThan(CaptureColorAnalysis.contrast(.init(red: 119, green: 119, blue: 119), white), 4.5)
    }
    func testLinearAverageAndTextCandidateOnBlackWhiteRegion() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(.init(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(NSColor.black.cgColor); context.fill(.init(x: 0, y: 0, width: 20, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let result = try CaptureColorAnalysis.region(image, bounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(result.textCandidate.hex, "#000000"); XCTAssertEqual(result.backgroundCandidate.hex, "#FFFFFF")
        XCTAssertEqual(result.minorityFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.average.red, 231) // linear .8 encoded to sRGB, not arithmetic 204
        let single = try CaptureColorAnalysis.region(image, bounds: CGRect(x: 0.19, y: 0.5, width: 0.01, height: 0.01))
        XCTAssertEqual(single.average.hex, "#000000")
        XCTAssertThrowsError(try CaptureColorAnalysis.region(image, bounds: .init(x: -1, y: 0, width: 1, height: 1)))
    }
}
