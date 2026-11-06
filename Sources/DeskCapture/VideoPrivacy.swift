import Foundation
import CoreImage

struct VideoPrivacyCue: Codable, Identifiable, Equatable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable { case screen, camera, canvas
        var title: String { switch self { case .screen: L10n.text("屏幕源画面"); case .camera: L10n.text("摄像头源画面"); case .canvas: L10n.text("最终画布") } }
    }
    enum Kind: String, Codable, CaseIterable, Sendable { case opaque, highlight
        var title: String { self == .opaque ? L10n.text("实色遮盖") : L10n.text("高亮（不脱敏）") }
    }
    var id = UUID()
    var start: Double
    var end: Double
    var target = Target.screen
    var kind = Kind.opaque
    var x = 0.2, y = 0.2, width = 0.3, height = 0.2
    var endX: Double? = nil
    var endY: Double? = nil
    var padding = 0.003
    var valid: Bool {
        let base = [start, end, x, y, width, height, padding]
        return base.allSatisfy(\.isFinite) && start >= 0 && end > start && end <= 1_000_000 && x >= 0 && y >= 0 && width >= 0.001 && height >= 0.001 && x + width <= 1.000001 && y + height <= 1.000001 && (0...0.05).contains(padding) &&
            ((endX == nil && endY == nil) || (endX.map { $0.isFinite && $0 >= 0 && $0 + width <= 1.000001 } == true && endY.map { $0.isFinite && $0 >= 0 && $0 + height <= 1.000001 } == true))
    }
    func rect(at time: Double) -> CGRect {
        let amount = min(1, max(0, (time - start) / (end - start)))
        return CGRect(x: x + ((endX ?? x) - x) * amount, y: y + ((endY ?? y) - y) * amount, width: width, height: height)
    }
}

struct VideoPrivacyTimeline: Sendable {
    let cues: [VideoPrivacyCue]
    init(_ cues: [VideoPrivacyCue], duration: Double) throws {
        guard duration.isFinite, duration > 0, cues.count <= 500, Set(cues.map(\.id)).count == cues.count,
              cues.allSatisfy({ $0.valid && $0.end <= duration + 0.001 }) else { throw CaptureError.message(L10n.text("视频区域最多500段，时间与归一化坐标必须有效且位于原片内。")) }
        self.cues = cues
    }
    /// A conservative frame-support interval, bounded to the current edited
    /// section so a reordered neighbour cannot change the source-time mask.
    static func sourceWindow(outputTime: Double, fps: Double, plan: VideoEditPlan) -> ClosedRange<Double> {
        let section = RecordingOptics.section(at: outputTime, plan: plan)
        let half = 1 / max(1, fps)
        let a = max(section.lowerBound, outputTime - half), b = min(max(section.lowerBound, section.upperBound.nextDown), outputTime + half)
        let sourceA = RecordingEffectsExporter.sourceTime(a, plan: plan), sourceB = RecordingEffectsExporter.sourceTime(max(a, b), plan: plan)
        return min(sourceA, sourceB)...max(sourceA, sourceB)
    }
    func rectangles(target: VideoPrivacyCue.Target, window: ClosedRange<Double>, bounds: CGRect) -> [(VideoPrivacyCue.Kind, CGRect)] {
        cues.filter { $0.target == target && $0.start <= window.upperBound + 0.000001 && $0.end >= window.lowerBound - 0.000001 }
            .sorted { $0.kind == .highlight && $1.kind == .opaque }
            .map { cue in
                let a = cue.rect(at: max(cue.start, window.lowerBound)), b = cue.rect(at: min(cue.end, window.upperBound))
                let union = a.union(b)
                let pixels = CGRect(x: bounds.minX + union.minX * bounds.width, y: bounds.minY + union.minY * bounds.height, width: union.width * bounds.width, height: union.height * bounds.height)
                let margin = cue.kind == .opaque ? max(2, min(bounds.width, bounds.height) * cue.padding) : 0
                return (cue.kind, pixels.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds))
            }
    }
    func apply(_ image: CIImage, target: VideoPrivacyCue.Target, window: ClosedRange<Double>) -> CIImage {
        rectangles(target: target, window: window, bounds: image.extent).reduce(image) { frame, item in
            let color = item.0 == .opaque ? CIColor.black : CIColor(red: 1, green: 0.8, blue: 0, alpha: 0.28)
            return CIImage(color: color).cropped(to: item.1).composited(over: frame)
        }.cropped(to: image.extent)
    }
    func mapped(to plan: VideoEditPlan) -> [(id: UUID, start: Double, end: Double)] {
        var result: [(UUID, Double, Double)] = [], offset = 0.0
        for (range, rate) in zip(plan.ranges, plan.rates) {
            for cue in cues {
                let a = max(range.start.seconds, cue.start), b = min(range.end.seconds, cue.end)
                if b > a { result.append((cue.id, offset + (a - range.start.seconds) / rate, offset + (b - range.start.seconds) / rate)) }
            }
            offset += range.duration.seconds / rate
        }
        return result
    }
}
