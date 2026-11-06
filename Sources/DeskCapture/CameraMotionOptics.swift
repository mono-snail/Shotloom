import CoreImage
import Foundation

/// Layout exposure uses the current decoded, already privacy-masked camera and
/// screen images only. It never fetches a neighbouring source frame.
enum CameraMotionOptics {
    static func poses(at time: Double, fps: Double, section: ClosedRange<Double>, canvas: CGSize,
                      options: RecordingOpticsOptions, motion: (Double) -> CameraLayoutPose) -> [CameraLayoutPose] {
        let base = motion(time)
        guard options.motionBlur, options.cameraMotionBlur == true, options.shutter > 0, options.maximumTrail > 0,
              fps.isFinite, fps > 0, canvas.width > 0, canvas.height > 0 else { return [base] }
        let count = min(7, max(3, options.samples)), half = options.shutter / fps / 2
        func distance(_ a: CGRect, _ b: CGRect) -> Double {
            func corners(_ rect: CGRect) -> [CGPoint] {
                [.init(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY), .init(x: rect.minX, y: rect.maxY), .init(x: rect.maxX, y: rect.maxY)]
            }
            return zip(corners(a), corners(b)).map { pair in
                hypot((pair.0.x - pair.1.x) * canvas.width, (pair.0.y - pair.1.y) * canvas.height)
            }.max() ?? 0
        }
        func linear(_ sample: CameraLayoutPose, amount t: Double) -> CameraLayoutPose {
            func n(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
            func box(_ a: CGRect, _ b: CGRect) -> CGRect { .init(x: n(a.minX, b.minX), y: n(a.minY, b.minY), width: n(a.width, b.width), height: n(a.height, b.height)) }
            return .init(screen: box(base.screen, sample.screen), screenOpacity: n(base.screenOpacity, sample.screenOpacity),
                         camera: box(base.camera, sample.camera), cameraOpacity: n(base.cameraOpacity, sample.cameraOpacity), radius: n(base.radius, sample.radius))
        }
        let result = (0..<count).map { index in
            let moment = min(max(section.lowerBound, section.upperBound.nextDown), max(section.lowerBound, time + (Double(index) / Double(count - 1) * 2 - 1) * half))
            let sample = motion(moment), displacement = max(distance(base.camera, sample.camera), distance(base.screen, sample.screen))
            return linear(sample, amount: displacement > options.maximumTrail ? options.maximumTrail / displacement : 1)
        }
        return result.allSatisfy({ $0 == base }) ? [base] : result
    }
    static func composite(_ camera: CIImage, screen: CIImage, canvas: CGRect, poses: [CameraLayoutPose], options: CameraOverlayOptions) -> CIImage {
        guard let first = poses.first else { return screen }
        if poses.count == 1 || poses.allSatisfy({ $0 == first }) { return CameraLayoutTimeline.composite(camera, screen: screen, canvas: canvas, pose: first, options: options) }
        let weight = 1 / Double(poses.count)
        // CIColorMatrix operates on unpremultiplied color; weighting alpha alone
        // weights premultiplied RGB once. Scaling RGB too darkens by weight².
        let taps = poses.map { pose in
            CameraLayoutTimeline.composite(camera, screen: screen, canvas: canvas, pose: pose, options: options)
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)])
        }
        return taps.dropFirst().reduce(taps[0]) { $1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) }.cropped(to: canvas)
    }
}
