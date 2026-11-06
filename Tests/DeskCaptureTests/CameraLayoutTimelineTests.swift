import XCTest
import AppKit
import CoreImage
@testable import DeskCapture

final class CameraLayoutTimelineTests: XCTestCase {
    func testRejectsOverlapsInvalidRangesAndDuplicateIdentities() {
        let a = CameraLayoutCue(start: 1, end: 3)
        XCTAssertThrowsError(try CameraLayoutTimeline([a, .init(start: 2, end: 4)], duration: 5))
        XCTAssertThrowsError(try CameraLayoutTimeline([a, a], duration: 5))
        XCTAssertThrowsError(try CameraLayoutTimeline([.init(start: 0, end: 10)], duration: 5))
        var invalid = a; invalid.transition = .nan
        XCTAssertThrowsError(try CameraLayoutTimeline([invalid], duration: 5))
    }
    func testCutReorderRepeatAndSpeedMapToOriginalLayouts() throws {
        let full = CameraLayoutCue(start: 4, end: 6, mode: .cameraOnly, transition: 0)
        let hidden = CameraLayoutCue(start: 2, end: 3, mode: .hidden, transition: 0)
        let timeline = try CameraLayoutTimeline([full, hidden], duration: 8)
        let sections = [VideoSection(start: 4, end: 6, speed: 2), VideoSection(start: 0, end: 3), VideoSection(start: 4, end: 6)]
        let captions = [CaptionSegment(start: 1, end: 2, text: "removed", keep: false)]
        let plan = try VideoEditPlan(duration: 8, start: 0, end: 8, captions: captions, sections: sections)
        let mapped = timeline.mapped(to: plan)
        XCTAssertEqual(mapped.count, 3)
        XCTAssertEqual(mapped[0].start, 0, accuracy: 0.0001); XCTAssertEqual(mapped[0].end, 1, accuracy: 0.0001)
        XCTAssertEqual(mapped[1].start, 2, accuracy: 0.0001); XCTAssertEqual(mapped[1].end, 3, accuracy: 0.0001)
        XCTAssertEqual(mapped[2].start, 3, accuracy: 0.0001); XCTAssertEqual(mapped[2].end, 5, accuracy: 0.0001)
        let canvas = CGSize(width: 1920, height: 1080), camera = CGSize(width: 640, height: 480), options = CameraOverlayOptions()
        func pose(_ output: Double) -> CameraLayoutPose { timeline.pose(at: RecordingEffectsExporter.sourceTime(output, plan: plan), canvas: canvas, camera: camera, options: options) }
        XCTAssertEqual(pose(0.5).screenOpacity, 0)
        XCTAssertEqual(pose(1).screenOpacity, 1) // Exact cut boundary switches to source 0.
        XCTAssertEqual(pose(2.5).cameraOpacity, 0)
        XCTAssertEqual(pose(4).screenOpacity, 0)
    }
    func testAdjacentTransitionsRemainContinuousAndHiddenEndsHalfOpen() throws {
        let timeline = try CameraLayoutTimeline([.init(start: 0, end: 2, mode: .cameraOnly, transition: 0.3),
                                               .init(start: 2, end: 4, mode: .splitLeft, transition: 0.3)], duration: 5)
        let size = CGSize(width: 200, height: 100), camera = CGSize(width: 100, height: 100), options = CameraOverlayOptions()
        let before = timeline.pose(at: 1.999999, canvas: size, camera: camera, options: options)
        let boundary = timeline.pose(at: 2, canvas: size, camera: camera, options: options)
        XCTAssertEqual(before.camera.width, boundary.camera.width, accuracy: 0.0001)
        XCTAssertEqual(boundary.screenOpacity, 0)
        let settled = timeline.pose(at: 2.5, canvas: size, camera: camera, options: options)
        XCTAssertEqual(settled.camera.width, 0.38, accuracy: 0.0001)
        let hidden = try CameraLayoutTimeline([.init(start: 1, end: 2, mode: .hidden, transition: 0)], duration: 3)
        XCTAssertEqual(hidden.pose(at: 1, canvas: size, camera: camera, options: options).cameraOpacity, 0)
        XCTAssertEqual(hidden.pose(at: 2, canvas: size, camera: camera, options: options).cameraOpacity, 1)
    }
    func testSyntheticCompositorPlacesBothSourcesAndHidesCamera() throws {
        let canvas = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screen = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: canvas)
        let camera = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let context = CIContext(options: [.cacheIntermediates: false]), options = CameraOverlayOptions()
        for mode in [CameraLayoutCue.Mode.hidden, .cameraOnly, .splitLeft, .splitRight] {
            let timeline = try CameraLayoutTimeline([.init(start: 0, end: 3, mode: mode, transition: 0)], duration: 4)
            let pose = timeline.pose(at: 1, canvas: canvas.size, camera: camera.extent.size, options: options)
            let result = CameraLayoutTimeline.composite(camera, screen: screen, canvas: canvas, pose: pose, options: options)
            let image = try XCTUnwrap(context.createCGImage(result, from: canvas))
            let left = CapturePixelColor.hex(image, at: CGPoint(x: 30, y: 50)), right = CapturePixelColor.hex(image, at: CGPoint(x: 150, y: 50))
            switch mode {
            case .hidden: XCTAssertEqual(left, "#0000FF"); XCTAssertEqual(right, "#0000FF")
            case .cameraOnly: XCTAssertEqual(left, "#FF0000"); XCTAssertEqual(right, "#FF0000")
            case .splitLeft: XCTAssertEqual(left, "#FF0000"); XCTAssertEqual(right, "#0000FF")
            case .splitRight: XCTAssertEqual(left, "#0000FF"); XCTAssertEqual(right, "#FF0000")
            default: XCTFail("Unexpected fixture mode")
            }
        }
    }
    func testStudioRoundTripAndLegacyOptionsWithoutCameraTimeline() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-layout-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("fixture.mp4")
        var effects = RecordingEffectsOptions(); effects.cameraLayouts = [.init(start: 1, end: 3, mode: .splitRight)]
        try RecordingStudioProject(effects: effects).save(video)
        XCTAssertEqual(RecordingStudioProject.load(video).effects?.cameraLayouts, effects.cameraLayouts)
        let stored = try Data(contentsOf: RecordingStudioProject.url(for: video))
        var invalid = effects
        invalid.cameraLayouts = [.init(start: 1, end: 3), .init(start: 2, end: 4)]
        XCTAssertThrowsError(try RecordingStudioProject(effects: invalid).save(video))
        XCTAssertEqual(try Data(contentsOf: RecordingStudioProject.url(for: video)), stored)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(effects)) as? [String: Any])
        json.removeValue(forKey: "cameraLayouts")
        let old = try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.cameraLayouts)
    }
}
