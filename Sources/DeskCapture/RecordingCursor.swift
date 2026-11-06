import Foundation
import SwiftUI

struct CursorHiddenRange: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
}
struct CursorPathSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var fromX = 0.5, fromY = 0.5, toX = 0.5, toY = 0.5
}
struct RecordingCursorOptions: Codable, Equatable {
    var hideWhenIdle = false
    var idleSeconds = 2.0
    var easing = RecordingEasing.smooth
    var hidden: [CursorHiddenRange] = []
    var paths: [CursorPathSegment] = []
    var active: Bool { hideWhenIdle || !hidden.isEmpty || !paths.isEmpty }
    func validate(duration: Double) throws {
        func valid(_ start: Double, _ end: Double) -> Bool {
            start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration + 0.001
        }
        guard duration.isFinite, duration > 0, idleSeconds.isFinite, (0.5...30).contains(idleSeconds),
              hidden.count <= 200, paths.count <= 200, Set(hidden.map(\.id)).count == hidden.count,
              Set(paths.map(\.id)).count == paths.count, hidden.allSatisfy({ valid($0.start, $0.end) }),
              paths.allSatisfy({ valid($0.start, $0.end) && [$0.fromX, $0.fromY, $0.toX, $0.toY].allSatisfy { $0.isFinite && (0...1).contains($0) } }) else {
            throw CaptureError.message(L10n.text("光标时间或坐标无效，隐藏和轨迹片段各最多200段。"))
        }
        let sorted = paths.sorted { $0.start < $1.start }
        for index in sorted.indices.dropFirst() where sorted[index].start < sorted[index - 1].end { throw CaptureError.message(L10n.text("光标轨迹片段不能重叠。")) }
    }
}
struct RecordingCursorTimeline {
    let pointers: [RecordedInteraction]
    let activity: [Double]
    init(events: [RecordedInteraction]) {
        let valid = events.filter { $0.time.isFinite && $0.time >= 0 && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }.sorted { $0.time < $1.time }
        pointers = valid.filter { $0.kind == .pointer }
        var moments: [Double] = [], last: CGPoint?
        for event in valid where event.kind != .shortcut {
            let point = CGPoint(x: event.x, y: event.y)
            if event.kind == .click || last == nil || hypot(point.x - last!.x, point.y - last!.y) >= 0.001 {
                moments.append(event.time); last = point
            }
        }
        activity = moments
    }
    func point(at time: Double, options: RecordingCursorOptions) -> CGPoint? {
        guard time.isFinite, !options.hidden.contains(where: { time >= $0.start && time < $0.end }) else { return nil }
        if let path = options.paths.first(where: { time >= $0.start && time < $0.end }) {
            let t = options.easing.value((time - path.start) / (path.end - path.start))
            // Explicit authored paths stay visible even while the recorded mouse was idle.
            return CGPoint(x: path.fromX + (path.toX - path.fromX) * t, y: path.fromY + (path.toY - path.fromY) * t)
        }
        if options.hideWhenIdle {
            var lo = 0, hi = activity.count
            while lo < hi { let middle = (lo + hi) / 2; if activity[middle] <= time { lo = middle + 1 } else { hi = middle } }
            guard lo > 0, time - activity[lo - 1] < options.idleSeconds else { return nil }
        }
        guard let first = pointers.first, time >= first.time else { return nil }
        return RecordingMotion.pointer(at: time, events: pointers)
    }
}

enum EditableCursorSource {
    static func resolve(_ video: URL, metadata: RecordingInteractions?) throws -> URL {
        if metadata?.smoothCursor == true { return video }
        guard let name = metadata?.editableCursorSource, !name.isEmpty, name.utf8.count < 256,
              name == URL(fileURLWithPath: name).lastPathComponent, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), name.hasSuffix(".mp4") else {
            throw CaptureError.message(L10n.text("此视频的光标已写入像素或未记录独立轨迹，无法安全隐藏或移动。请使用启用平滑光标的新录屏。"))
        }
        let source = video.deletingLastPathComponent().appendingPathComponent(name)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.standardizedFileURL != video.standardizedFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              RecordingInteractions.load(source)?.smoothCursor == true else { throw CaptureError.message(L10n.text("可编辑光标原片缺失或无有效独立轨迹，原视频保持不变。")) }
        return source
    }
}

struct RecordingCursorEditor: View {
    @Binding var options: RecordingCursorOptions
    let currentTime: () -> Double
    let duration: Double
    let available: Bool
    @State private var error: String?
    var body: some View {
        VideoInspectorGroup(L10n.text("光标"), grid: false) {
            VStack(alignment: .leading, spacing: 6) {
                VideoControlGrid {
                Toggle(L10n.text("自动隐藏"), isOn: $options.hideWhenIdle)
                if options.hideWhenIdle {
                    InspectorSlider(title: L10n.text("等待时间"), value: $options.idleSeconds, range: 0.5...30, unit: L10n.text(" 秒"), decimals: 1)
                }
                VideoField(title: L10n.text("轨迹缓动")) { Picker(L10n.text("轨迹缓动"), selection: $options.easing) { ForEach(RecordingEasing.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu) }
                VideoField(title: L10n.text("隐藏片段")) { Button(L10n.text("添加片段")) { add(path: false) } }
                VideoField(title: L10n.text("移动轨迹")) { Button(L10n.text("添加轨迹")) { add(path: true) } }
                }
                ForEach($options.hidden) { $range in
                    VideoControlGrid {
                        VideoField(title: L10n.text("隐藏开始（秒）")) { TextField(L10n.text("开始"), value: $range.start, format: .number) }
                        VideoField(title: L10n.text("隐藏结束（秒）")) { TextField(L10n.text("结束"), value: $range.end, format: .number) }
                        VideoField(title: L10n.text("片段操作")) { Button(L10n.text("删除片段")) { options.hidden.removeAll { $0.id == range.id } } }
                    }
                }
                ForEach($options.paths) { $path in
                    VideoControlGrid {
                        VideoField(title: L10n.text("轨迹开始（秒）")) { TextField(L10n.text("开始"), value: $path.start, format: .number) }
                        VideoField(title: L10n.text("轨迹结束（秒）")) { TextField(L10n.text("结束"), value: $path.end, format: .number) }
                        VideoField(title: L10n.text("起点水平位置")) { TextField("X", value: $path.fromX, format: .number) }
                        VideoField(title: L10n.text("起点垂直位置")) { TextField("Y", value: $path.fromY, format: .number) }
                        VideoField(title: L10n.text("终点水平位置")) { TextField("X", value: $path.toX, format: .number) }
                        VideoField(title: L10n.text("终点垂直位置")) { TextField("Y", value: $path.toY, format: .number) }
                        VideoField(title: L10n.text("轨迹操作")) { Button(L10n.text("删除轨迹")) { options.paths.removeAll { $0.id == path.id } } }
                    }
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }.disabled(!available)
        }
    }
    private func add(path: Bool) {
        let start = max(0, min(currentTime(), duration - 0.1)), end = min(duration, start + 2)
        var draft = options
        if path { draft.paths.append(.init(start: start, end: end)) } else { draft.hidden.append(.init(start: start, end: end)) }
        do { try draft.validate(duration: duration); options = draft; error = nil } catch { self.error = error.localizedDescription }
    }
}
