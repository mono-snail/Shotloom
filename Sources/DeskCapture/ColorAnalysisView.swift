import SwiftUI

struct ColorAnalysisView: View {
    let image: CGImage
    let close: () -> Void
    @State private var foreground = "#000000"
    @State private var background = "#FFFFFF"
    @State private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var analysis: RegionColorAnalysis?
    @State private var error: String?
    @State private var busy = false
    @State private var drag: CGRect?
    @State private var role = 0
    private var key: String { String(describing: region) }
    var body: some View {
        StudioWorkspace(title: L10n.text("颜色与对比度"), symbol: "eyedropper") {
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark", action: close)
        } preview: {
                GeometryReader { geometry in
                    let factor = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
                    Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                        .overlay(alignment: .topLeading) {
                            let selection = drag ?? CGRect(x: region.minX * size.width, y: region.minY * size.height, width: region.width * size.width, height: region.height * size.height)
                            Rectangle().stroke(Palette.ice, lineWidth: 2).frame(width: selection.width, height: selection.height).offset(x: selection.minX, y: selection.minY)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            drag = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                          width: abs(value.translation.width), height: abs(value.translation.height))
                        }.onEnded { value in
                            defer { drag = nil }
                            if hypot(value.translation.width, value.translation.height) < 3 {
                                let x = min(CGFloat(image.width - 1), max(0, value.location.x / size.width * CGFloat(image.width)))
                                let y = min(CGFloat(image.height - 1), max(0, value.location.y / size.height * CGFloat(image.height)))
                                region = CGRect(x: floor(x) / CGFloat(image.width), y: floor(y) / CGFloat(image.height), width: 1 / CGFloat(image.width), height: 1 / CGFloat(image.height))
                            } else if let drag {
                                let selected = CGRect(x: drag.minX / size.width, y: drag.minY / size.height, width: drag.width / size.width, height: drag.height / size.height)
                                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                                if !selected.isEmpty { region = selected }
                            }
                        })
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
        } inspector: {
            InspectorGroup(L10n.text("取色"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("取色用途")) { Picker(L10n.text("取色用途"), selection: $role) { Text(L10n.text("前景")).tag(0); Text(L10n.text("背景")).tag(1) }.labelsHidden() }.pickerStyle(.segmented).labelsHidden()
                InspectorField(title: L10n.text("前景 HEX")) { TextField("#000000", text: $foreground).accessibilityLabel(L10n.text("前景 HEX")) }
                InspectorField(title: L10n.text("背景 HEX")) { TextField("#FFFFFF", text: $background).accessibilityLabel(L10n.text("背景 HEX")) }
            }
            if let fg = CaptureColorAnalysis.parse(foreground), let bg = CaptureColorAnalysis.parse(background) {
                InspectorGroup(L10n.text("对比度"), initiallyExpanded: true) {
                    Text(L10n.text("文字示例 Aa")).font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color(nsColor: fg.color)).frame(maxWidth: .infinity, minHeight: 64)
                        .background(Color(nsColor: bg.color), in: RoundedRectangle(cornerRadius: 8))
                    let ratio = CaptureColorAnalysis.contrast(fg, bg)
                    Text(String(format: "%.2f : 1", ratio)).font(.system(size: 28, weight: .medium, design: .monospaced))
                    LabeledContent(L10n.text("普通文字 AA"), value: ratio >= 4.5 ? L10n.text("通过") : L10n.text("未达标"))
                    LabeledContent(L10n.text("大号文字 AA"), value: ratio >= 3 ? L10n.text("通过") : L10n.text("未达标"))
                    LabeledContent(L10n.text("普通文字 AAA"), value: ratio >= 7 ? L10n.text("通过") : L10n.text("未达标"))
                }
            } else { Label(L10n.text("请输入六位 HEX"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let analysis {
                InspectorGroup(L10n.text("选区颜色")) {
                    LabeledContent(L10n.text("平均色"), value: analysis.average.hex).monospacedDigit().textSelection(.enabled)
                    Button(L10n.text("平均色设为\(role == 0 ? L10n.text("前景") : L10n.text("背景"))")) { assign(analysis.average) }
                    Button(L10n.text("采用文字与背景色")) { foreground = analysis.textCandidate.hex; background = analysis.backgroundCandidate.hex }
                    Button(L10n.text("复制平均色 OKLCH")) {
                        let value = CaptureColorAnalysis.oklch(analysis.average).css
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            if busy { ProgressView().controlSize(.small); Text(L10n.text("分析选区…")) }
            Spacer()
        }
            .task(id: key) {
                busy = true; error = nil; analysis = nil
                let bounds = region
                let targetRole = role
                let targetValue = role == 0 ? foreground : background
                let worker = Task.detached { try CaptureColorAnalysis.region(image, bounds: bounds) }
                do {
                    let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, bounds == region else { return }; analysis = result; busy = false
                    // A completed sample must not overwrite a later edit or another color role.
                    if role == targetRole, (role == 0 ? foreground : background) == targetValue,
                       bounds.width <= 1 / CGFloat(image.width) * 1.01 && bounds.height <= 1 / CGFloat(image.height) * 1.01 {
                        assign(result.average)
                    }
                } catch { if !Task.isCancelled, bounds == region { busy = false; self.error = error.localizedDescription } }
            }
    }
    private func assign(_ value: CaptureColorSample) { if role == 0 { foreground = value.hex } else { background = value.hex } }
}
