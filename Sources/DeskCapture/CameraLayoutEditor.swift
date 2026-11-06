import SwiftUI

struct CameraLayoutEditor: View {
    @Binding var cues: [CameraLayoutCue]
    let currentTime: () -> Double
    let duration: Double
    let defaults: CameraOverlayOptions
    @State private var error: String?
    var body: some View {
        VideoInspectorGroup(L10n.text("分段布局"), grid: false) {
            VStack(alignment: .leading, spacing: 8) {
                VideoControlGrid { VideoField(title: L10n.text("分段布局")) { Button(L10n.text("添加片段")) {
                    let currentTime = currentTime()
                    let start = max(0, min(currentTime, max(0, duration - 0.1))), end = min(duration, start + 3)
                    guard end > start, cues.count < 200 else { return }
                    let cue = CameraLayoutCue(start: start, end: end, x: defaults.x, y: defaults.y, width: defaults.width)
                    do { _ = try CameraLayoutTimeline(cues + [cue], duration: duration); cues.append(cue); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(duration <= 0 || cues.count >= 200) } }
                ForEach($cues) { $cue in
                    VideoControlGrid {
                        VideoField(title: L10n.text("开始时间（秒）")) { TextField(L10n.text("开始秒"), value: $cue.start, format: .number) }
                        VideoField(title: L10n.text("结束时间（秒）")) { TextField(L10n.text("结束秒"), value: $cue.end, format: .number) }
                        VideoField(title: L10n.text("布局")) { Picker(L10n.text("布局"), selection: $cue.mode) { ForEach(CameraLayoutCue.Mode.allCases) { Text($0.title).tag($0) } } }
                        VideoField(title: L10n.text("过渡时间（秒）")) { TextField(L10n.text("过渡秒"), value: $cue.transition, format: .number) }
                        if cue.mode == .pip {
                            InspectorSlider(title: L10n.text("水平位置"), value: $cue.x, range: 0...1, scale: 100, unit: "%")
                            InspectorSlider(title: L10n.text("垂直位置"), value: $cue.y, range: 0...1, scale: 100, unit: "%")
                            InspectorSlider(title: L10n.text("画面大小"), value: $cue.width, range: 0.1...0.45, scale: 100, unit: "%")
                        }
                        VideoField(title: L10n.text("片段操作")) { Button(L10n.text("移除片段")) { cues.removeAll { $0.id == cue.id } } }
                    }
                    if !cue.valid || cue.end > duration { Text(L10n.text("请修正此段的起止时间、位置或过渡参数。")).foregroundStyle(.orange) }
                    Divider()
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }.padding(.top, 6).onChange(of: cues) { _, _ in error = nil }
        }
    }
}
