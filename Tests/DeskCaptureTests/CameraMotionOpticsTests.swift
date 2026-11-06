import XCTest
import CoreImage
@testable import DeskCapture

final class CameraMotionOpticsTests: XCTestCase {
    private func pose(_ x: Double) -> CameraLayoutPose { .init(camera: .init(x: x, y: 0, width: 0.5, height: 1), radius: 0) }
    func testCameraExposureHonorsCutWindowAndAllCornerTrailBounds() {
        var options = RecordingOpticsOptions(); options.motionBlur = true; options.cameraMotionBlur = true; options.samples = 7; options.maximumTrail = 2
        let canvas = CGSize(width: 1000, height: 600), base = pose(0.5)
        var times: [Double] = []
        let values = CameraMotionOptics.poses(at: 1, fps: 30, section: 1...2, canvas: canvas, options: options) { moment in
            times.append(moment)
            var value = self.pose(moment / 2); value.camera.size.height += (moment - 1) * 4; return value
        }
        XCTAssertTrue(times.allSatisfy { $0 >= 1 && $0 < 2 })
        for item in values {
            for point in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
                let ax = base.camera.minX + point.x * base.camera.width, ay = base.camera.minY + point.y * base.camera.height
                let bx = item.camera.minX + point.x * item.camera.width, by = item.camera.minY + point.y * item.camera.height
                XCTAssertLessThanOrEqual(hypot((ax - bx) * canvas.width, (ay - by) * canvas.height), 2.0001)
            }
        }
    }
    func testStationaryAndLegacyOptionsKeepSinglePose() throws {
        let current = pose(0.2), canvas = CGSize(width: 32, height: 16)
        var options = RecordingOpticsOptions(); options.motionBlur = true
        XCTAssertEqual(CameraMotionOptics.poses(at: 1, fps: 30, section: 0...2, canvas: canvas, options: options) { _ in current }, [current])
        options.cameraMotionBlur = true
        XCTAssertEqual(CameraMotionOptics.poses(at: 1, fps: 30, section: 0...2, canvas: canvas, options: options) { _ in current }, [current])
        let legacy = Data("{\"easing\":\"smooth\",\"motionBlur\":true,\"shutter\":0.5,\"samples\":5,\"maximumTrail\":12}".utf8)
        XCTAssertNil(try JSONDecoder().decode(RecordingOpticsOptions.self, from: legacy).cameraMotionBlur)
    }
    func testLinearExposureAveragesOnlyProvidedCurrentImagesAndKeepsAlpha() throws {
        let canvas = CGRect(x: 0, y: 0, width: 32, height: 16)
        let screen = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: canvas)
        let camera = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        var options = CameraOverlayOptions(); options.mirrored = false; options.shape = .cutout
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
        func pixels(_ image: CIImage) -> [Float] {
            var values = [Float](repeating: 0, count: 32 * 16 * 4)
            context.render(image, toBitmap: &values, rowBytes: 32 * 4 * MemoryLayout<Float>.size, bounds: canvas, format: .RGBAf, colorSpace: space)
            return values
        }
        let a = pose(0), b = pose(0.5)
        let first = pixels(CameraLayoutTimeline.composite(camera, screen: screen, canvas: canvas, pose: a, options: options))
        let second = pixels(CameraLayoutTimeline.composite(camera, screen: screen, canvas: canvas, pose: b, options: options))
        let mixed = pixels(CameraMotionOptics.composite(camera, screen: screen, canvas: canvas, poses: [a, b], options: options))
        let maximumError = mixed.indices.map { abs(mixed[$0] - (first[$0] + second[$0]) / 2) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximumError, 0.001)
        for index in stride(from: 3, to: mixed.count, by: 4) { XCTAssertEqual(mixed[index], 1, accuracy: 0.001) }
        XCTAssertEqual(pixels(CameraMotionOptics.composite(camera, screen: screen, canvas: canvas, poses: [a, a, a], options: options)), first)
    }
}
