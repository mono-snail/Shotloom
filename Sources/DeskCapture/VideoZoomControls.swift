import SwiftUI

/// Match the existing screen/camera render branches without clearing dormant
/// options or lens segments when automatic reframing takes over.
struct VideoMotionAvailability {
    let manualZoom: Bool
    let screenOptics: Bool
    let cameraOptics: Bool
    var optics: Bool { screenOptics || cameraOptics }

    init(options: RecordingEffectsOptions, lenses: [RecordingLens], hasInteractions: Bool, cameraReady: Bool) {
        let reframing = options.reframing?.enabled == true
        manualZoom = !reframing
        screenOptics = !reframing && ((hasInteractions && options.smartZoom) || lenses.contains(where: \.valid))
        cameraOptics = cameraReady && options.camera.enabled &&
            (options.cameraLayouts?.isEmpty == false || options.cameraAutomation?.active == true || reframing)
    }
}

struct VideoZoomControls: View {
    @Binding var options: RecordingEffectsOptions
    @Binding var lenses: [RecordingLens]
    @Binding var x: Double
    @Binding var y: Double
    @Binding var zoom: Double
    @Binding var lensDuration: Double
    let hasInteractions: Bool
    let trimStart: Double
    let trimEnd: Double
    let currentTime: () -> Double
    var initiallyExpanded = false

    var body: some View {
        VideoInspectorGroup(L10n.text("缩放"), initiallyExpanded: initiallyExpanded, grid: false) {
            VideoControlGrid {
                if hasInteractions {
                    Toggle(L10n.text("自动跟随点击"), isOn: $options.smartZoom)
                    if options.smartZoom {
                        InspectorSlider(title: L10n.text("自动倍率"), value: $options.zoom, range: 1.2...2.4, unit: "×", decimals: 1)
                    }
                }
                InspectorSlider(title: L10n.text("水平焦点"), value: $x, range: 0...1, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("垂直焦点"), value: $y, range: 0...1, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("放大倍率"), value: $zoom, range: 1...4, unit: "×", decimals: 1)
                InspectorSlider(title: L10n.text("持续时间"), value: $lensDuration, range: 0.5...10, unit: L10n.text(" 秒"), decimals: 1)
                VideoField(title: L10n.text("放大片段")) {
                    Button(L10n.text("添加片段")) {
                        let time = currentTime(), start = max(trimStart, time)
                        let end = min(trimEnd, start + lensDuration)
                        guard end > start else { return }
                        lenses.append(RecordingLens(start: start, end: end, x: x, y: y, zoom: zoom))
                    }
                }
            }
            ForEach($lenses) { $lens in
                VideoControlGrid {
                    VideoField(title: L10n.text("开始时间（秒）")) { TextField(L10n.text("开始秒"), value: $lens.start, format: .number) }
                    VideoField(title: L10n.text("结束时间（秒）")) { TextField(L10n.text("结束秒"), value: $lens.end, format: .number) }
                    InspectorSlider(title: L10n.text("片段倍率"), value: $lens.zoom, range: 1...4, unit: "×", decimals: 1)
                    VideoField(title: L10n.text("片段操作")) {
                        Button(L10n.text("删除片段")) {
                            let id = lens.id
                            lenses.removeAll { $0.id == id }
                        }
                    }
                }
            }
        }
    }
}
