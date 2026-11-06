import Foundation
import CoreImage
import SwiftUI

enum RecordingEasing: String, Codable, CaseIterable {
    case smooth, gentle, linear
    var title: String { switch self { case .smooth: L10n.text("平滑"); case .gentle: L10n.text("柔和"); case .linear: L10n.text("线性") } }
    func value(_ input: Double) -> Double {
        let t = min(1, max(0, input))
        switch self {
        case .smooth: return t * t * (3 - 2 * t)
        case .gentle: return t * t * t * (t * (t * 6 - 15) + 10)
        case .linear: return t
        }
    }
}

struct RecordingOpticsOptions: Codable, Equatable {
    var easing = RecordingEasing.smooth
    var motionBlur = false
    var cameraMotionBlur: Bool? = nil
    var shutter = 0.5
    var samples = 5
    var maximumTrail = 12.0
    func validate() throws {
        guard shutter.isFinite, (0...0.8).contains(shutter), (3...7).contains(samples),
              maximumTrail.isFinite, (0...24).contains(maximumTrail) else {
            throw CaptureError.message(L10n.text("镜头光学参数超出范围。"))
        }
    }
}

enum RecordingOptics {
    static func transform(zoom: Double, focus: CGPoint, bounds: CGRect) -> CGAffineTransform {
        let x = min(0, max(bounds.width * (1 - zoom), bounds.midX - focus.x * bounds.width * zoom))
        let y = min(0, max(bounds.height * (1 - zoom), bounds.midY - focus.y * bounds.height * zoom))
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: x, ty: y)
    }
    /// Samples only geometry within the current edited section. Every tap uses
    /// the current decoded image: no neighbouring frame or removed content enters.
    static func transforms(at time: Double, fps: Double, section: ClosedRange<Double>, bounds: CGRect,
                           options: RecordingOpticsOptions, motion: (Double) -> (Double, CGPoint)) -> [CGAffineTransform] {
        let current = motion(time), base = transform(zoom: current.0, focus: current.1, bounds: bounds)
        guard options.motionBlur, options.shutter > 0, options.maximumTrail > 0, fps.isFinite, fps > 0 else { return [base] }
        let count = min(7, max(3, options.samples)), half = options.shutter / fps / 2
        return (0..<count).map { index in
            // Avoid sampling the following section at the exact upper boundary.
            let t = min(max(section.lowerBound, section.upperBound.nextDown), max(section.lowerBound, time + (Double(index) / Double(count - 1) * 2 - 1) * half))
            let pose = motion(t), sample = transform(zoom: pose.0, focus: pose.1, bounds: bounds)
            let corners = [CGPoint.zero, CGPoint(x: bounds.width, y: 0), CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height)]
            let displacement = corners.map { point -> Double in
                let a = point.applying(base), b = point.applying(sample); return hypot(a.x - b.x, a.y - b.y)
            }.max() ?? 0
            let amount = displacement > options.maximumTrail ? options.maximumTrail / displacement : 1
            return CGAffineTransform(a: base.a + (sample.a - base.a) * amount, b: 0, c: 0,
                                     d: base.d + (sample.d - base.d) * amount,
                                     tx: base.tx + (sample.tx - base.tx) * amount, ty: base.ty + (sample.ty - base.ty) * amount)
        }
    }
    static func render(_ image: CIImage, bounds: CGRect, transforms: [CGAffineTransform]) -> CIImage {
        guard let first = transforms.first else { return image.cropped(to: bounds) }
        if transforms.count == 1 || transforms.allSatisfy({ $0 == first }) { return image.transformed(by: first).cropped(to: bounds) }
        let weight = 1 / Double(transforms.count)
        let scaled = CIVector(x: 1, y: 0, z: 0, w: 0)
        let taps = transforms.map { image.transformed(by: $0).cropped(to: bounds).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": scaled, "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)]) }
        return taps.dropFirst().reduce(taps[0]) { $1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) }.cropped(to: bounds)
    }
    static func section(at time: Double, plan: VideoEditPlan) -> ClosedRange<Double> {
        var start = 0.0
        for (range, rate) in zip(plan.ranges, plan.rates) {
            let end = start + range.duration.seconds / rate
            if time < end { return start...end }; start = end
        }
        return start...start
    }
}

/// CI builds a lazy graph; these times deliberately exclude GPU evaluation.
/// Compare paired full-export wall times to measure the total optical cost.
final class RecordingOpticsMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, taps = 0
    private var graphSeconds = 0.0
    func add(seconds: Double, taps: Int) {
        lock.lock(); defer { lock.unlock() }
        frames += 1; self.taps += taps; graphSeconds += seconds
    }
    func report(exportSeconds: Double, options: RecordingOpticsOptions) async {
        guard let path = ProcessInfo.processInfo.environment["DESKCAPTURE_PERFORMANCE_REPORT_DIR"], !path.isEmpty else { return }
        let snapshot: (Int, Int, Double) = { lock.lock(); defer { lock.unlock() }; return (frames, taps, graphSeconds) }()
        await Task.detached(priority: .utility) {
            let report: [String: Any] = ["kind": "R34-optics", "motionBlur": options.motionBlur, "cameraMotionBlur": options.cameraMotionBlur == true, "samples": options.samples,
                "transformTapScope": "screen geometry only; full export wall time includes camera layout exposure",
                "frames": snapshot.0, "transformTaps": snapshot.1, "graphBuildCPUSeconds": snapshot.2,
                "fullExportWallSeconds": exportSeconds, "timingScope": "graph time excludes lazy GPU evaluation; full export includes all processing; compare matched on/off runs"]
            do {
                let root = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("r34-optics-\(UUID()).json"), options: .atomic)
            } catch { NSLog("DeskCapture optics measurement unavailable: %@", error.localizedDescription) }
        }.value
    }
}

struct RecordingOpticsEditor: View {
    @Binding var options: RecordingOpticsOptions
    var screenMotionAvailable = true
    var cameraMotionAvailable = true
    var initiallyExpanded = false
    var body: some View {
        VideoInspectorGroup(L10n.text("镜头运动"), initiallyExpanded: initiallyExpanded) {
            if screenMotionAvailable {
                VideoField(title: L10n.text("缩放缓动")) { Picker(L10n.text("缩放缓动"), selection: $options.easing) { ForEach(RecordingEasing.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
            }
            Toggle(L10n.text("运动模糊"), isOn: $options.motionBlur)
            if options.motionBlur {
                if cameraMotionAvailable {
                    Toggle(L10n.text("摄像头运动模糊"), isOn: Binding(get: { options.cameraMotionBlur == true }, set: { options.cameraMotionBlur = $0 }))
                }
                if screenMotionAvailable || (cameraMotionAvailable && options.cameraMotionBlur == true) {
                    InspectorSlider(title: L10n.text("快门"), value: $options.shutter, range: 0...0.8, scale: 100, unit: "%")
                    VideoField(title: L10n.text("采样数"), value: "\(options.samples)") { Stepper(L10n.text("采样数"), value: $options.samples, in: 3...7) }
                    InspectorSlider(title: L10n.text("拖影上限"), value: $options.maximumTrail, range: 0...24, unit: " px")
                }
            }
        }
    }
}
