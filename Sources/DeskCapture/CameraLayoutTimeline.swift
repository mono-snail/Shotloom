import AppKit
import CoreImage

struct CameraLayoutCue: Codable, Identifiable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case pip, cameraOnly, splitLeft, splitRight, hidden
        var id: String { rawValue }
        var title: String { switch self { case .pip: L10n.text("画中画"); case .cameraOnly: L10n.text("摄像头全屏"); case .splitLeft: L10n.text("摄像头居左分屏"); case .splitRight: L10n.text("摄像头居右分屏"); case .hidden: L10n.text("隐藏摄像头") } }
    }
    var id = UUID()
    var start: Double
    var end: Double
    var mode = Mode.pip
    var x = 0.85
    var y = 0.82
    var width = 0.22
    var transition = 0.3 // seconds on source timeline; scales with clip rate
    var valid: Bool {
        [start, end, x, y, width, transition].allSatisfy(\.isFinite) && start >= 0 && end > start && end <= 1_000_000 &&
        (0...1).contains(x) && (0...1).contains(y) && (0.1...0.45).contains(width) && (0...2).contains(transition)
    }
}
struct CameraLayoutPose: Equatable {
    var screen = CGRect(x: 0, y: 0, width: 1, height: 1)
    var screenOpacity = 1.0
    var camera: CGRect
    var cameraOpacity = 1.0
    var radius: Double
    static func blend(_ a: Self, _ b: Self, _ amount: Double) -> Self {
        let t = max(0, min(1, amount)), smooth = t * t * (3 - 2 * t)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * smooth }
        func box(_ x: CGRect, _ y: CGRect) -> CGRect { .init(x: mix(x.minX, y.minX), y: mix(x.minY, y.minY), width: mix(x.width, y.width), height: mix(x.height, y.height)) }
        return .init(screen: box(a.screen, b.screen), screenOpacity: mix(a.screenOpacity, b.screenOpacity), camera: box(a.camera, b.camera), cameraOpacity: mix(a.cameraOpacity, b.cameraOpacity), radius: mix(a.radius, b.radius))
    }
}
struct CameraLayoutTimeline {
    let cues: [CameraLayoutCue]
    init(_ cues: [CameraLayoutCue], duration: Double) throws {
        guard cues.count <= 200, duration.isFinite, duration > 0, Set(cues.map(\.id)).count == cues.count,
              cues.allSatisfy({ $0.valid && $0.end <= duration + 0.001 }) else { throw CaptureError.message(L10n.text("摄像头布局最多200段，时间/位置/过渡需有效且位于原视频内。")) }
        let ordered = cues.sorted { $0.start < $1.start }
        for index in ordered.indices.dropFirst() where ordered[index].start < ordered[index - 1].end {
            throw CaptureError.message(L10n.text("摄像头布局片段不能重叠，请调整起止时间。"))
        }
        self.cues = ordered
    }
    private func pose(_ cue: CameraLayoutCue?, canvas: CGSize, camera: CGSize, options: CameraOverlayOptions) -> CameraLayoutPose {
        let mode = cue?.mode ?? .pip
        let ratio = options.shape == .circle ? 1 : camera.height / max(1, camera.width)
        let pixels = min(canvas.width * (cue?.width ?? options.width), canvas.height * 0.5 / max(0.01, ratio))
        let width = pixels / canvas.width, height = pixels * ratio / canvas.height
        let rect = CGRect(x: min(1 - width, max(0, (cue?.x ?? options.x) - width / 2)),
                          y: min(1 - height, max(0, (cue?.y ?? options.y) - height / 2)), width: width, height: height)
        var pose = CameraLayoutPose(camera: rect, cameraOpacity: options.enabled ? 1 : 0, radius: options.shape == .circle ? 0.5 : options.shape == .rounded ? 0.12 : 0)
        guard options.enabled else { return pose }
        switch mode {
        case .pip: break
        case .hidden: pose.cameraOpacity = 0
        case .cameraOnly: pose.screenOpacity = 0; pose.camera = CGRect(x: 0, y: 0, width: 1, height: 1); pose.radius = 0
        case .splitLeft: pose.camera = CGRect(x: 0, y: 0, width: 0.38, height: 1); pose.screen = CGRect(x: 0.4, y: 0, width: 0.6, height: 1); pose.radius = 0
        case .splitRight: pose.camera = CGRect(x: 0.62, y: 0, width: 0.38, height: 1); pose.screen = CGRect(x: 0, y: 0, width: 0.6, height: 1); pose.radius = 0
        }
        return pose
    }
    func pose(at time: Double, canvas: CGSize, camera: CGSize, options: CameraOverlayOptions) -> CameraLayoutPose {
        guard [canvas.width, canvas.height, camera.width, camera.height].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return .init(camera: .zero, cameraOpacity: 0, radius: 0)
        }
        let base = pose(nil, canvas: canvas, camera: camera, options: options)
        guard time.isFinite, canvas.width > 0, canvas.height > 0,
              let index = cues.firstIndex(where: { time >= $0.start && time < $0.end }) else { return base }
        let cue = cues[index], target = pose(cue, canvas: canvas, camera: camera, options: options)
        let ramp = min(cue.transition, (cue.end - cue.start) / 2)
        guard ramp > 0 else { return target }
        let prior = index > 0 && abs(cues[index - 1].end - cue.start) < 0.000001 ? pose(cues[index - 1], canvas: canvas, camera: camera, options: options) : base
        if time < cue.start + ramp { return .blend(prior, target, (time - cue.start) / ramp) }
        let nextIsAdjacent = index + 1 < cues.count && abs(cues[index + 1].start - cue.end) < 0.000001
        if !nextIsAdjacent && time > cue.end - ramp { return .blend(target, base, (time - cue.end + ramp) / ramp) }
        return target
    }
    func permitsAutomaticPlacement(at time: Double) -> Bool {
        guard let cue = cues.first(where: { time >= $0.start && time < $0.end }) else { return true }
        return cue.mode == .pip || cue.mode == .hidden
    }
    func mapped(to plan: VideoEditPlan) -> [(id: UUID, start: Double, end: Double)] {
        var output: [(UUID, Double, Double)] = [], offset = 0.0
        for (range, rate) in zip(plan.ranges, plan.rates) {
            for cue in cues {
                let a = max(cue.start, range.start.seconds), b = min(cue.end, range.end.seconds)
                if b > a { output.append((cue.id, offset + (a - range.start.seconds) / rate, offset + (b - range.start.seconds) / rate)) }
            }
            offset += range.duration.seconds / rate
        }
        return output
    }
    static func composite(_ camera: CIImage, screen: CIImage, canvas: CGRect, pose: CameraLayoutPose, options: CameraOverlayOptions) -> CIImage {
        guard !canvas.isEmpty, !canvas.isInfinite, camera.extent.width > 0, camera.extent.height > 0, screen.extent.width > 0, screen.extent.height > 0 else { return screen }
        func box(_ normalized: CGRect) -> CGRect { CGRect(x: canvas.minX + normalized.minX * canvas.width, y: canvas.minY + normalized.minY * canvas.height, width: normalized.width * canvas.width, height: normalized.height * canvas.height) }
        func fit(_ image: CIImage, into rect: CGRect, fill: Bool) -> CIImage {
            let source = image.extent, factor = fill ? max(rect.width / source.width, rect.height / source.height) : min(rect.width / source.width, rect.height / source.height)
            return image.transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
                .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                .transformed(by: CGAffineTransform(translationX: rect.midX - source.width * factor / 2, y: rect.midY - source.height * factor / 2)).cropped(to: rect)
        }
        func opacity(_ image: CIImage, _ amount: Double) -> CIImage { image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)]) }
        var result = CIImage(color: .black).cropped(to: canvas)
        if pose.screenOpacity > 0 { result = opacity(fit(screen, into: box(pose.screen), fill: false), pose.screenOpacity).composited(over: result) }
        if pose.cameraOpacity > 0 {
            var frame = camera
            if options.mirrored { frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY)); frame = frame.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: frame.extent.width, ty: 0)) }
            let rect = box(pose.camera), fitted = fit(frame, into: rect, fill: true)
            let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": rect.width * pose.radius, "inputColor": CIColor.white])!.outputImage!
            let foreground = fitted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: canvas), kCIInputMaskImageKey: mask])
            result = opacity(foreground, pose.cameraOpacity).composited(over: result)
        }
        return result.cropped(to: canvas)
    }
}
