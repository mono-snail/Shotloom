import Foundation
import CoreImage

struct CameraManualOverride: Codable, Identifiable, Equatable {
    enum Visibility: String, Codable, CaseIterable { case automatic, show, hide }
    var id = UUID()
    var start: Double
    var end: Double
    var visibility = Visibility.automatic
    var focusX: Double?
    var focusY: Double?
    var valid: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && end <= 3600 &&
        ((focusX == nil && focusY == nil) || (focusX.map { $0.isFinite && (0...1).contains($0) } == true && focusY.map { $0.isFinite && (0...1).contains($0) } == true))
    }
}
struct CameraAutomationOptions: Codable, Equatable {
    var followFace = false
    var hideWhenQuiet = false
    var thresholdDB = -42.0
    var minimumQuiet = 1.5
    var fade = 0.2
    var cropZoom = 1.25
    var overrides: [CameraManualOverride] = []
    var active: Bool { followFace || hideWhenQuiet || !overrides.isEmpty }
    func validate(duration: Double) throws {
        guard duration.isFinite, duration > 0, (!active || duration <= 3600),
              [thresholdDB, minimumQuiet, fade, cropZoom].allSatisfy(\.isFinite), (-72 ... -18).contains(thresholdDB),
              (0.5...5).contains(minimumQuiet), (0.05...1).contains(fade), (1...2).contains(cropZoom),
              overrides.count <= 200, Set(overrides.map(\.id)).count == overrides.count,
              overrides.allSatisfy({ $0.valid && $0.end <= duration + 0.001 }) else { throw CaptureError.message(L10n.text("摄像头自动参数无效；自动分析支持最长60分钟，手动覆盖最多200段。")) }
        let sorted = overrides.sorted { $0.start < $1.start }
        for index in sorted.indices.dropFirst() where sorted[index].start < sorted[index - 1].end { throw CaptureError.message(L10n.text("摄像头手动覆盖片段不能重叠。")) }
    }
}
struct FaceTrackingSample { let time: Double; let center: CGPoint }
struct StableFaceTracker {
    private(set) var center = CGPoint(x: 0.5, y: 0.5)
    private var target: CGRect?
    private var pending: CGRect?
    private var pendingCount = 0
    private var lastTime: Double?
    mutating func update(_ faces: [CGRect], at time: Double) -> CGPoint {
        guard time.isFinite else { return center }
        let valid = faces.filter { !$0.isNull && !$0.isInfinite && $0.width >= 0.04 && $0.height >= 0.04 && CGRect(x: 0, y: 0, width: 1, height: 1).contains($0) }
        let selected: CGRect?
        if let old = target { selected = valid.min { hypot($0.midX - old.midX, $0.midY - old.midY) < hypot($1.midX - old.midX, $1.midY - old.midY) } }
        else { selected = valid.max { $0.width * $0.height < $1.width * $1.height } }
        let first = lastTime == nil
        let dt = min(1, max(0, time - (lastTime ?? time))); lastTime = time
        guard let selected else { pending = nil; pendingCount = 0; return center }
        if first { target = selected; center = CGPoint(x: selected.midX, y: selected.midY); return center }
        if let target, hypot(selected.midX - target.midX, selected.midY - target.midY) > 0.25 {
            if let pending, hypot(pending.midX - selected.midX, pending.midY - selected.midY) < 0.12 { pendingCount += 1 }
            else { pending = selected; pendingCount = 1 }
            guard pendingCount >= 3 else { return center }
        }
        target = selected; pending = nil; pendingCount = 0
        let amount = 1 - exp(-dt / 0.35), maxStep = 0.25 * dt
        let dx = (selected.midX - center.x) * amount, dy = (selected.midY - center.y) * amount, distance = hypot(dx, dy)
        let factor = distance > maxStep && distance > 0 ? maxStep / distance : 1
        center.x += dx * factor; center.y += dy * factor; return center
    }
}
struct QuietCameraInterval { let start: Double; let end: Double }
struct CameraAutomationAnalysis {
    var faces: [FaceTrackingSample] = []
    var quiet: [QuietCameraInterval] = []
    var audioAvailable = false
    var faceDetections = 0
    static func quietIntervals(_ bins: [Double?], step: Double = 0.1, options: CameraAutomationOptions) -> [QuietCameraInterval] {
        var intervals: [QuietCameraInterval] = [], start: Double?
        for index in 0...bins.count {
            let time = Double(index) * step
            let quiet = index < bins.count && bins[index].map { $0 < options.thresholdDB } == true
            if quiet { if start == nil { start = time } }
            else if let began = start {
                if time - began > options.minimumQuiet { intervals.append(.init(start: began + options.minimumQuiet, end: time)) }
                start = nil
            }
        }
        return intervals
    }
    func visibility(at time: Double, options: CameraAutomationOptions) -> Double {
        if let manual = options.overrides.first(where: { time >= $0.start && time < $0.end }) {
            if manual.visibility == .show { return 1 }; if manual.visibility == .hide { return 0 }
        }
        guard options.hideWhenQuiet, audioAvailable,
              let interval = quiet.first(where: { time >= $0.start && time < $0.end + options.fade }) else { return 1 }
        let peak = min(1, (interval.end - interval.start) / options.fade)
        let amount = time < interval.end ? min(1, (time - interval.start) / options.fade) : peak * max(0, 1 - (time - interval.end) / options.fade)
        return 1 - amount
    }
    func focus(at time: Double, options: CameraAutomationOptions) -> CGPoint? {
        if let manual = options.overrides.first(where: { time >= $0.start && time < $0.end }), let x = manual.focusX, let y = manual.focusY { return CGPoint(x: x, y: y) }
        guard options.followFace else { return nil }
        guard !faces.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        var lo = 0, hi = faces.count
        while lo < hi { let mid = (lo + hi) / 2; if faces[mid].time <= time { lo = mid + 1 } else { hi = mid } }
        let a = faces[max(0, lo - 1)], b = faces[min(faces.count - 1, lo)]
        let t = b.time > a.time ? min(1, max(0, (time - a.time) / (b.time - a.time))) : 0
        return CGPoint(x: a.center.x + (b.center.x - a.center.x) * t, y: a.center.y + (b.center.y - a.center.y) * t)
    }
    func reframed(_ image: CIImage, at time: Double, options: CameraAutomationOptions) -> CIImage {
        guard let focus = focus(at: time, options: options), options.cropZoom > 1 else { return image }
        let extent = image.extent, w = extent.width / options.cropZoom, h = extent.height / options.cropZoom
        let rect = CGRect(x: min(extent.maxX - w, max(extent.minX, extent.minX + focus.x * extent.width - w / 2)),
                          y: min(extent.maxY - h, max(extent.minY, extent.minY + focus.y * extent.height - h / 2)), width: w, height: h)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }
}
