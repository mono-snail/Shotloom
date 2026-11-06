import XCTest
import CoreText
import CoreGraphics
@testable import DeskCapture

final class VideoTextAvoidanceTests: XCTestCase {
    func testTemporalCandidatesUseBothBoundingSamplesAndClampEnds() {
        let a = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), b = CGRect(x: 0.6, y: 0.7, width: 0.2, height: 0.1)
        let coverage = VideoTextCoverage(samples: [.init(time: 0, boxes: [a]), .init(time: 2, boxes: [b])])
        XCTAssertEqual(coverage.boxes(at: 1), [a, b]); XCTAssertEqual(coverage.boxes(at: 20), [b])
        XCTAssertTrue(coverage.boxes(at: .nan).isEmpty)
    }
    func testActualTextDetectionReturnsNormalizedCandidateNearRenderedHeading() async throws {
        let boxes = try await Task.detached { () throws -> [CGRect] in
            let space = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: 512, height: 160, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("Fixture allocation failed") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 160))
            let font = CTFontCreateWithName("Menlo" as CFString, 32, nil)
            let text = NSAttributedString(string: "Protected text 123", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 20, y: 64); CTLineDraw(CTLineCreateWithAttributedString(text), context)
            guard let image = context.makeImage() else { throw CaptureError.message("Fixture image failed") }
            return try VideoTextCoverage.detect(image)
        }.value
        XCTAssertFalse(boxes.isEmpty)
        XCTAssertTrue(boxes.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0) })
        XCTAssertTrue(boxes.contains { !$0.intersection(CGRect(x: 0.03, y: 0.35, width: 0.9, height: 0.3)).isEmpty })
    }
    func testTimeGridAvoidanceIsContinuousAndIndependentOfRequestOrder() {
        let canvas = CGRect(x: 0, y: 0, width: 1000, height: 1000), safe = canvas
        let current = CameraLayoutPose(camera: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2), radius: 0.1)
        func target(_ time: Double) -> CameraLayoutPose { var value = current; value.camera.origin.x = time < 0.2 ? 0.1 : 0.7; return value }
        func value(_ time: Double) -> CameraLayoutPose { VideoReframing.smoothAvoidingCamera(current, at: time, section: 0...2, canvas: canvas, safe: safe, enabled: true, target: target) }
        XCTAssertLessThan(abs(value(0.199).camera.minX - value(0.201).camera.minX), 0.01)
        XCTAssertLessThan(abs(value(0.3999).camera.minX - value(0.4001).camera.minX), 0.01)
        let times = [0.0, 0.1, 0.2, 0.3, 0.4, 1.0]
        let forward = times.map(value), reverse = times.reversed().map(value).reversed()
        XCTAssertEqual(forward, Array(reverse))
        for pose in forward { XCTAssertTrue(safe.contains(CGRect(x: pose.camera.minX * 1000, y: pose.camera.minY * 1000, width: pose.camera.width * 1000, height: pose.camera.height * 1000))) }
        var split = current; split.screen = CGRect(x: 0.4, y: 0, width: 0.6, height: 1)
        XCTAssertEqual(VideoReframing.smoothAvoidingCamera(split, at: 0.3, section: 0...2, canvas: canvas, safe: safe, enabled: true, target: target), split)
    }
    func testSmoothingNeverConsultsAnotherEditedSectionAndAuthoredModesHavePriority() throws {
        let current = CameraLayoutPose(camera: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2), radius: 0.1)
        var queried: [Double] = []
        _ = VideoReframing.smoothAvoidingCamera(current, at: 1.01, section: 1...1.15, canvas: CGRect(x: 0, y: 0, width: 1000, height: 1000), safe: CGRect(x: 0, y: 0, width: 1000, height: 1000), enabled: true) { time in queried.append(time); return current }
        XCTAssertTrue(queried.allSatisfy { $0 >= 1 && $0 < 1.15 })
        let cue = CameraLayoutCue(start: 1, end: 2, mode: .cameraOnly)
        let timeline = try CameraLayoutTimeline([cue], duration: 3)
        XCTAssertFalse(timeline.permitsAutomaticPlacement(at: 1.99)); XCTAssertTrue(timeline.permitsAutomaticPlacement(at: 2))
    }
}
