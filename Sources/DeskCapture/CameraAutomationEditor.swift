import SwiftUI

struct CameraAutomationEditor: View {
    @Binding var options: CameraAutomationOptions
    let currentTime: () -> Double
    let duration: Double
    @State private var error: String?
    var body: some View {
        VideoInspectorGroup(L10n.text("自动画中画"), grid: false) {
            VStack(alignment: .leading, spacing: 8) {
                VideoControlGrid {
                Toggle(L10n.text("跟随人脸"), isOn: $options.followFace)
                if options.followFace {
                    InspectorSlider(title: L10n.text("放大倍率"), value: $options.cropZoom, range: 1...2, unit: "×", decimals: 1)
                }
                Toggle(L10n.text("静音时隐藏"), isOn: $options.hideWhenQuiet)
                if options.hideWhenQuiet {
                    InspectorSlider(title: L10n.text("静音阈值"), value: $options.thresholdDB, range: -72 ... -18, unit: " dB")
                    InspectorSlider(title: L10n.text("等待时间"), value: $options.minimumQuiet, range: 0.5...5, unit: L10n.text(" 秒"), decimals: 1)
                    InspectorSlider(title: L10n.text("淡入淡出"), value: $options.fade, range: 0.05...1, unit: L10n.text(" 秒"), decimals: 2)
                }
                VideoField(title: L10n.text("显示规则")) { Button(L10n.text("添加规则")) {
                    let start = min(max(0, currentTime()), max(0, duration - 0.1)), end = min(duration, start + 3)
                    guard end > start, options.overrides.count < 200 else { return }
                    var draft = options; draft.overrides.append(.init(start: start, end: end))
                    do { try draft.validate(duration: duration); options = draft; error = nil } catch { self.error = error.localizedDescription }
                }.disabled(duration <= 0 || duration > 3600 || options.overrides.count >= 200) }
                }
                ForEach($options.overrides) { $manual in
                    VideoControlGrid {
                        VideoField(title: L10n.text("开始时间（秒）")) { TextField(L10n.text("开始"), value: $manual.start, format: .number) }
                        VideoField(title: L10n.text("结束时间（秒）")) { TextField(L10n.text("结束"), value: $manual.end, format: .number) }
                        VideoField(title: L10n.text("可见性")) {
                            Picker(L10n.text("可见性"), selection: $manual.visibility) {
                                Text(L10n.text("自动判断")).tag(CameraManualOverride.Visibility.automatic)
                                Text(L10n.text("显示")).tag(CameraManualOverride.Visibility.show)
                                Text(L10n.text("隐藏")).tag(CameraManualOverride.Visibility.hide)
                            }
                        }
                        Toggle(L10n.text("锁定裁切焦点"), isOn: Binding(get: { manual.focusX != nil }, set: { enabled in manual.focusX = enabled ? 0.5 : nil; manual.focusY = enabled ? 0.5 : nil }))
                        if manual.focusX != nil {
                            InspectorSlider(title: L10n.text("水平焦点"), value: Binding(get: { manual.focusX ?? 0.5 }, set: { manual.focusX = $0 }), range: 0...1, scale: 100, unit: "%")
                            InspectorSlider(title: L10n.text("垂直焦点"), value: Binding(get: { manual.focusY ?? 0.5 }, set: { manual.focusY = $0 }), range: 0...1, scale: 100, unit: "%")
                        }
                        VideoField(title: L10n.text("规则操作")) { Button(L10n.text("移除规则")) { options.overrides.removeAll { $0.id == manual.id } } }
                    }
                    Divider()
                }
                if let error { Text(error).foregroundStyle(.orange) }
            }.padding(.top, 6)
        }
    }
}
