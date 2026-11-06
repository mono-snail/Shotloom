import XCTest
import CoreImage
@testable import DeskCapture

final class RecordingOpticsTests: XCTestCase {
    func testEasingEndpointsMonotonicityAndGentleVelocity() {
        for easing in RecordingEasing.allCases {
            XCTAssertEqual(easing.value(-1), 0); XCTAssertEqual(easing.value(2), 1)
            let values = (0...100).map { easing.value(Double($0) / 100) }
            XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        }
        XCTAssertLessThan(RecordingEasing.gentle.value(0.01), RecordingEasing.smooth.value(0.01))
    }
    func testShutterCannotSampleAcrossEditedSectionAndTrailIsBounded() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        var options = RecordingOpticsOptions(); options.motionBlur = true; options.samples = 7; options.maximumTrail = 3
        var sampled: [Double] = []
        let motion: (Double) -> (Double, CGPoint) = { time in sampled.append(time); return (1 + time, CGPoint(x: 0.8, y: 0.2)) }
        let transforms = RecordingOptics.transforms(at: 1, fps: 30, section: 1...2, bounds: bounds, options: options, motion: motion)
        XCTAssertEqual(transforms.count, 7); XCTAssertTrue(sampled.allSatisfy { $0 >= 1 && $0 < 2 })
        let base = RecordingOptics.transform(zoom: 2, focus: CGPoint(x: 0.8, y: 0.2), bounds: bounds)
        for transform in transforms {
            for point in [CGPoint.zero, CGPoint(x: 1000, y: 600)] {
                let a = point.applying(base), b = point.applying(transform)
                XCTAssertLessThanOrEqual(hypot(a.x - b.x, a.y - b.y), 3.00001)
            }
        }
        sampled = []
        _ = RecordingOptics.transforms(at: Double(2).nextDown, fps: 30, section: 1...2, bounds: bounds, options: options, motion: motion)
        XCTAssertTrue(sampled.allSatisfy { $0 >= 1 && $0 < 2 })
    }
    func testDisabledAndStaticTransformsPreservePixelsAndAlpha() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5)).cropped(to: bounds)
        var options = RecordingOpticsOptions()
        let disabled = RecordingOptics.transforms(at: 1, fps: 30, section: 0...2, bounds: bounds, options: options) { _ in (1, .zero) }
        XCTAssertEqual(disabled.count, 1)
        options.motionBlur = true
        let stationary = RecordingOptics.transforms(at: 1, fps: 30, section: 0...2, bounds: bounds, options: options) { _ in (1, .zero) }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func pixels(_ value: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32 * 24 * 4)
            context.render(value, toBitmap: &bytes, rowBytes: 32 * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()); return bytes
        }
        XCTAssertEqual(pixels(RecordingOptics.render(image, bounds: bounds, transforms: disabled)), pixels(image))
        XCTAssertEqual(pixels(RecordingOptics.render(image, bounds: bounds, transforms: stationary)), pixels(image))
        let shifted = stationary.enumerated().map { CGAffineTransform(translationX: Double($0.offset) / 10, y: 0) }
        let mixed = pixels(RecordingOptics.render(image, bounds: bounds, transforms: shifted))
        let original = pixels(image), interior = (12 * 32 + 16) * 4
        for channel in 0..<4 { XCTAssertEqual(Double(mixed[interior + channel]), Double(original[interior + channel]), accuracy: 1) }
    }
    func testProjectCompatibilityValidationAndRepeatedSectionBoundaries() throws {
        let legacy = Data("{\"start\":0,\"end\":2,\"x\":0.5,\"y\":0.5,\"zoom\":2,\"id\":\"\(UUID())\"}".utf8)
        let lens = try JSONDecoder().decode(RecordingLens.self, from: legacy)
        XCTAssertEqual(RecordingLens.motion(at: 1, lenses: [lens], easing: .gentle)?.0, 2)
        var options = RecordingOpticsOptions(); options.samples = 8
        XCTAssertThrowsError(try options.validate())
        options.samples = 5; options.shutter = .nan
        XCTAssertThrowsError(try options.validate())
        let plan = try VideoEditPlan(duration: 4, start: 0, end: 4, captions: [])
        XCTAssertEqual(RecordingOptics.section(at: 1, plan: plan), 0...4)
        let reordered = try VideoEditPlan(duration: 4, start: 0, end: 4, captions: [], sections: [
            VideoSection(start: 2, end: 4, speed: 2), VideoSection(start: 0, end: 2), VideoSection(start: 2, end: 4, speed: 0.5)])
        XCTAssertEqual(RecordingOptics.section(at: 0.99, plan: reordered), 0...1)
        XCTAssertEqual(RecordingOptics.section(at: 1, plan: reordered), 1...3)
        XCTAssertEqual(RecordingOptics.section(at: 3, plan: reordered), 3...7)
        var effects = RecordingEffectsOptions(); effects.optics = .init()
        let restored = try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects))
        XCTAssertEqual(restored.optics, effects.optics)
        effects.optics = nil
        XCTAssertNil(try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects)).optics)
    }
}
