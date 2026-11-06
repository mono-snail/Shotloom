import XCTest
import CoreImage
@testable import DeskCapture

final class VideoReframingTests: XCTestCase {
    func testCompleteFrameAndLockedEdgePlacementAcrossAspectRatios() {
        let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var options = VideoReframingOptions(); options.enabled = true
        for layout in [VideoCanvasLayout.landscape, .square, .portrait] {
            let canvas = CGRect(origin: .zero, size: layout.size(source: source.size))
            let safe = options.safeRect(canvas)
            let fit = source.applying(VideoReframing.placement(source: source, viewport: safe, focus: .zero, fill: false))
            XCTAssertGreaterThanOrEqual(fit.minX, safe.minX - 0.001); XCTAssertLessThanOrEqual(fit.maxX, safe.maxX + 0.001)
            XCTAssertGreaterThanOrEqual(fit.minY, safe.minY - 0.001); XCTAssertLessThanOrEqual(fit.maxY, safe.maxY + 0.001)
            for focus in [CGPoint.zero, CGPoint(x: 1, y: 1)] {
                let fill = source.applying(VideoReframing.placement(source: source, viewport: safe, focus: focus, fill: true))
                XCTAssertLessThanOrEqual(fill.minX, safe.minX + 0.001); XCTAssertGreaterThanOrEqual(fill.maxX, safe.maxX - 0.001)
                XCTAssertLessThanOrEqual(fill.minY, safe.minY + 0.001); XCTAssertGreaterThanOrEqual(fill.maxY, safe.maxY - 0.001)
            }
        }
    }
    func testCaptionBoundsAndCameraAvoidanceWithManualPriority() {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let safe = VideoReframingOptions().safeRect(canvas)
        let caption = VideoReframing.caption(CGSize(width: 1800, height: 400), in: safe)
        XCTAssertTrue(safe.insetBy(dx: -0.001, dy: -0.001).contains(caption))
        let pose = CameraLayoutPose(camera: CGRect(x: 0.05, y: 0.12, width: 0.2, height: 0.2), radius: 0.12)
        let adjusted = VideoReframing.avoidingCamera(pose, canvas: canvas, safe: safe, protected: [caption], locked: false)
        let pixels = CGRect(x: adjusted.camera.minX * 1000, y: adjusted.camera.minY * 1000, width: adjusted.camera.width * 1000, height: adjusted.camera.height * 1000)
        XCTAssertTrue(pixels.intersection(caption).isNull || pixels.intersection(caption).isEmpty)
        XCTAssertEqual(VideoReframing.avoidingCamera(pose, canvas: canvas, safe: safe, protected: [caption], locked: true).camera, pose.camera)
        var split = pose; split.screen = CGRect(x: 0.4, y: 0, width: 0.6, height: 1)
        XCTAssertEqual(VideoReframing.avoidingCamera(split, canvas: canvas, safe: safe, protected: [caption], locked: false).camera, split.camera)
    }
    func testFocusIsStableAndRepeatedSourceTimesMatch() throws {
        let events = [RecordedInteraction(time: 1, x: 0.95, y: 0.9, kind: .click), RecordedInteraction(time: 3, x: 0.1, y: 0.1, kind: .click)]
        let timeline = VideoFocusTimeline(events: events, duration: 5)
        for (a, b) in zip(timeline.samples, timeline.samples.dropFirst()) { XCTAssertLessThanOrEqual(hypot(a.x - b.x, a.y - b.y), 0.125001) }
        let plan = try VideoEditPlan(duration: 5, start: 0, end: 5, captions: [], sections: [VideoSection(start: 1, end: 3), VideoSection(start: 1, end: 3, speed: 2)])
        let points = plan.mapAll(1.5).map { timeline.focus(at: RecordingEffectsExporter.sourceTime($0, plan: plan)) }
        XCTAssertEqual(points.count, 2); XCTAssertEqual(points[0], points[1])
        XCTAssertEqual(VideoFocusTimeline(events: [], duration: 1).focus(at: 0.5), CGPoint(x: 0.5, y: 0.5))
    }
    func testGeometryDoesNotMutateSourcePixelsAndSettingsRoundTrip() throws {
        let bounds = CGRect(x: 0, y: 0, width: 32, height: 24)
        let image = CIImage(color: .red).cropped(to: bounds), context = CIContext()
        let before = try XCTUnwrap(context.createCGImage(image, from: bounds)).dataProvider?.data
        let transform = VideoReframing.placement(source: bounds, viewport: CGRect(x: 1, y: 2, width: 30, height: 20), focus: .zero, fill: false)
        _ = context.createCGImage(image.transformed(by: transform), from: bounds)
        let after = try XCTUnwrap(context.createCGImage(image, from: bounds)).dataProvider?.data
        XCTAssertEqual(before as Data?, after as Data?)
        var options = VideoReframingOptions(); options.enabled = true; options.mode = .locked; options.lockCamera = true
        var effects = RecordingEffectsOptions(); effects.reframing = options
        XCTAssertEqual(try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects)).reframing, options)
        options.safeTop = .infinity
        XCTAssertThrowsError(try options.validate())
    }
}
