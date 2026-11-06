import Foundation
import CoreImage
import SwiftUI

struct VideoReframingOptions: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case fitAll, activity, locked
        var title: String { switch self { case .fitAll: L10n.text("保留完整画面"); case .activity: L10n.text("跟随操作焦点"); case .locked: L10n.text("锁定焦点") } }
    }
    var enabled = false
    var mode = Mode.fitAll
    var focusX = 0.5, focusY = 0.5
    var safeTop = 0.06, safeBottom = 0.12, safeLeft = 0.05, safeRight = 0.08
    var avoidCamera = true
    var lockCamera = false
    var smoothCamera: Bool? = nil
    var avoidText: Bool? = nil
    var showGuides = true // UI only: never burned into the export.
    func validate() throws {
        guard [focusX, focusY].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [safeTop, safeBottom, safeLeft, safeRight].allSatisfy({ $0.isFinite && (0...0.3).contains($0) }) else {
            throw CaptureError.message(L10n.text("重新构图焦点或安全区参数无效。"))
        }
    }
    func safeRect(_ canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + canvas.width * safeLeft, y: canvas.minY + canvas.height * safeBottom,
               width: canvas.width * (1 - safeLeft - safeRight), height: canvas.height * (1 - safeTop - safeBottom))
    }
}

/// Source-time focus path: spatial easing is precomputed off the render callback.
struct VideoFocusTimeline {
    let samples: [CGPoint]
    init(events: [RecordedInteraction], duration: Double) {
        let clicks = events.filter { $0.kind == .click && $0.time.isFinite && $0.time >= 0 && $0.time <= duration && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }.sorted { $0.time < $1.time }
        var center = CGPoint(x: 0.5, y: 0.5), target = center, index = 0, result: [CGPoint] = []
        // <= 72,001 points even for a ten-hour source; longer sources hold final focus.
        let count = Int(ceil(min(36000, max(0, duration.isFinite ? duration : 0)) * 2)) + 1
        for sample in 0..<count {
            let time = Double(sample) / 2
            while index < clicks.count && clicks[index].time <= time { target = CGPoint(x: clicks[index].x, y: clicks[index].y); index += 1 }
            let dx = (target.x - center.x) * 0.5, dy = (target.y - center.y) * 0.5
            let length = hypot(dx, dy), amount = length > 0.125 ? 0.125 / length : 1
            center.x += dx * amount; center.y += dy * amount; result.append(center)
        }
        samples = result
    }
    func focus(at time: Double) -> CGPoint {
        guard !samples.isEmpty, time.isFinite else { return CGPoint(x: 0.5, y: 0.5) }
        let position = max(0, min(Double(samples.count - 1), time * 2)), index = Int(position), t = position - Double(index)
        let a = samples[index], b = samples[min(samples.count - 1, index + 1)]
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

enum VideoReframing {
    static func placement(source: CGRect, viewport: CGRect, focus: CGPoint, fill: Bool) -> CGAffineTransform {
        let scale = fill ? max(viewport.width / source.width, viewport.height / source.height) : min(viewport.width / source.width, viewport.height / source.height)
        func offset(_ center: Double, _ focus: Double, _ min: Double, _ max: Double, _ extent: Double, _ sourceMin: Double) -> Double {
            let desired = center - focus * extent * scale - sourceMin * scale
            if !fill { return center - (sourceMin + extent / 2) * scale }
            return Swift.min(min - sourceMin * scale, Swift.max(max - (sourceMin + extent) * scale, desired))
        }
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: offset(viewport.midX, focus.x, viewport.minX, viewport.maxX, source.width, source.minX),
            ty: offset(viewport.midY, focus.y, viewport.minY, viewport.maxY, source.height, source.minY))
    }
    static func viewport(canvas: CGRect, options: VideoReframingOptions, background: Bool, padding: Double, captions: Bool) -> CGRect {
        let inset = background ? min(canvas.width, canvas.height) * padding : 0
        var inner = canvas.insetBy(dx: inset, dy: inset)
        if options.enabled {
            let safe = options.safeRect(canvas); inner = inner.intersection(safe)
            if captions { let reserved = min(inner.height * 0.4, safe.height * 0.3 + 8); inner.origin.y += reserved; inner.size.height -= reserved }
        }
        return inner
    }
    /// Fixed time-grid targets make seeks and out-of-order render requests agree.
    /// Geometry may anticipate a change by <= 0.4 s; no future pixels are read.
    static func smoothAvoidingCamera(_ current: CameraLayoutPose, at time: Double, section: ClosedRange<Double>, canvas: CGRect, safe: CGRect,
                                     enabled: Bool, target: (Double) -> CameraLayoutPose) -> CameraLayoutPose {
        guard current.cameraOpacity > 0, current.screen == CGRect(x: 0, y: 0, width: 1, height: 1), current.camera.width < 0.6 else { return current }
        guard enabled else { return target(time) }
        let step = 0.4
        let a = max(section.lowerBound, section.lowerBound + floor(max(0, time - section.lowerBound) / step) * step)
        let b = min(max(a, section.upperBound.nextDown), a + step)
        let first = target(a), last = target(b)
        guard first.screen == current.screen, last.screen == current.screen, first.camera.width < 0.6, last.camera.width < 0.6 else { return target(time) }
        let progress = b > a ? min(1, max(0, (time - a) / (b - a))) : 0, t = progress * progress * (3 - 2 * progress)
        let width = min(current.camera.width * canvas.width, safe.width), height = min(current.camera.height * canvas.height, safe.height)
        let center = CGPoint(x: (first.camera.midX + (last.camera.midX - first.camera.midX) * t) * canvas.width,
                             y: (first.camera.midY + (last.camera.midY - first.camera.midY) * t) * canvas.height)
        var result = current
        result.camera = CGRect(x: min(safe.maxX - width, max(safe.minX, center.x - width / 2)) / canvas.width,
                               y: min(safe.maxY - height, max(safe.minY, center.y - height / 2)) / canvas.height,
                               width: width / canvas.width, height: height / canvas.height)
        return result
    }
    static func caption(_ size: CGSize, in safe: CGRect) -> CGRect {
        let scale = min(1, safe.width / max(1, size.width), safe.height * 0.3 / max(1, size.height))
        return CGRect(x: safe.midX - size.width * scale / 2, y: safe.minY, width: size.width * scale, height: size.height * scale)
    }
    static func avoidingCamera(_ pose: CameraLayoutPose, canvas: CGRect, safe: CGRect, protected: [CGRect], locked: Bool) -> CameraLayoutPose {
        // Full-screen and split camera layouts are authored explicitly in R32.
        guard !locked, pose.cameraOpacity > 0, pose.screen == CGRect(x: 0, y: 0, width: 1, height: 1), pose.camera.width < 0.6 else { return pose }
        let width = min(pose.camera.width * canvas.width, safe.width), height = min(pose.camera.height * canvas.height, safe.height)
        let original = CGRect(x: pose.camera.minX * canvas.width, y: pose.camera.minY * canvas.height, width: width, height: height)
        let clamped = CGRect(x: min(safe.maxX - width, max(safe.minX, original.minX)), y: min(safe.maxY - height, max(safe.minY, original.minY)), width: width, height: height)
        let candidates = [clamped] + [CGPoint(x: safe.minX, y: safe.minY), CGPoint(x: safe.maxX - width, y: safe.minY), CGPoint(x: safe.minX, y: safe.maxY - height), CGPoint(x: safe.maxX - width, y: safe.maxY - height)].map { CGRect(origin: $0, size: CGSize(width: width, height: height)) }
        func score(_ rect: CGRect) -> Double {
            let overlap = protected.reduce(0.0) { sum, region in let area = rect.intersection(region); return sum + (area.isNull ? 0 : area.width * area.height) }
            return overlap * 1000 + hypot(rect.midX - original.midX, rect.midY - original.midY)
        }
        let chosen = candidates.min { score($0) < score($1) } ?? clamped
        var result = pose
        result.camera = CGRect(x: chosen.minX / canvas.width, y: chosen.minY / canvas.height, width: width / canvas.width, height: height / canvas.height)
        return result
    }
}

struct VideoReframingEditor: View {
    @Binding var options: VideoReframingOptions
    var body: some View {
        VideoInspectorGroup(L10n.text("构图与安全区")) {
            Toggle(L10n.text("自动构图"), isOn: $options.enabled)
            if options.enabled {
                VideoField(title: L10n.text("构图方式")) { Picker(L10n.text("构图方式"), selection: $options.mode) {
                    ForEach(VideoReframingOptions.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu) }
                if options.mode == .locked {
                    InspectorSlider(title: L10n.text("水平焦点"), value: $options.focusX, range: 0...1, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("垂直焦点"), value: $options.focusY, range: 0...1, scale: 100, unit: "%")
                }
                InspectorSlider(title: L10n.text("上边距"), value: $options.safeTop, range: 0...0.3, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("下边距"), value: $options.safeBottom, range: 0...0.3, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("左边距"), value: $options.safeLeft, range: 0...0.3, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("右边距"), value: $options.safeRight, range: 0...0.3, scale: 100, unit: "%")
                Toggle(L10n.text("画中画自动避让"), isOn: $options.avoidCamera)
                if options.avoidCamera {
                    Toggle(L10n.text("平滑移动"), isOn: Binding(get: { options.smoothCamera != false }, set: { options.smoothCamera = $0 }))
                    Toggle(L10n.text("避让文字"), isOn: Binding(get: { options.avoidText == true }, set: { options.avoidText = $0 }))
                }
                Toggle(L10n.text("锁定摄像头位置"), isOn: $options.lockCamera)
                Toggle(L10n.text("显示安全区"), isOn: $options.showGuides)
            }
        }
    }
}

struct VideoSafeAreaGuide: View {
    let aspect: Double
    let options: VideoReframingOptions
    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, geometry.size.height * aspect), height = width / max(0.01, aspect)
            let canvas = CGRect(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2, width: width, height: height)
            let safe = options.safeRect(canvas)
            // SwiftUI's origin is top-left; export geometry's origin is bottom-left.
            Rectangle().stroke(.yellow.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(width: safe.width, height: safe.height)
                .position(x: safe.midX, y: canvas.minY + canvas.height * options.safeTop + safe.height / 2)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
