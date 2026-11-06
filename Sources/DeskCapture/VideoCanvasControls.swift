import AppKit
import SwiftUI

struct VideoCanvasControls: View {
    @Binding var options: RecordingEffectsOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoInspectorGroup(L10n.text("画布"), initiallyExpanded: true) {
                VideoField(title: L10n.text("比例")) {
                    Picker(L10n.text("比例"), selection: $options.layout) {
                        ForEach(VideoCanvasLayout.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu)
                }
                // Automatic reframing owns fill/fit in the renderer. Preserve the
                // manual choice for when that feature is switched off again.
                if options.reframing?.enabled != true {
                    Toggle(L10n.text("裁切填满"), isOn: $options.fillsCanvas)
                }
            }
            VideoInspectorGroup(L10n.text("背景"), initiallyExpanded: true) {
                Toggle(L10n.text("显示背景"), isOn: $options.background)
                if options.background {
                    VideoField(title: L10n.text("样式")) { VideoBackgroundStylePicker(selection: $options.style) }
                    InspectorSlider(title: L10n.text("留白"), value: $options.padding, range: 0...0.16, scale: 100, unit: "%", decimals: 1)
                    InspectorSlider(title: L10n.text("圆角"), value: $options.cornerRadius, range: 0...0.08, scale: 100, unit: "%", decimals: 1)
                }
            }
        }
    }
}

struct VideoBackgroundStylePicker: View {
    @Binding var selection: BeautifyStyle
    @State private var showingPalette = false

    var body: some View {
        Button { showingPalette = true } label: {
            HStack(spacing: 6) {
                VideoBackgroundSample(style: selection).frame(width: 26, height: 18)
                Text(selection.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }.frame(minHeight: 20)
        }.buttonStyle(StudioButtonStyle(command: true))
            .help(L10n.text("选择视频背景：\(selection.title)"))
            .accessibilityLabel(L10n.text("视频背景样式")).accessibilityValue(selection.title)
            .popover(isPresented: $showingPalette) {
                VideoBackgroundPalette(selected: selection) { style in
                    selection = style; showingPalette = false
                }
            }
    }
}

struct VideoBackgroundPalette: View {
    let selected: BeautifyStyle
    let choose: (BeautifyStyle) -> Void
    @FocusState private var focused: BeautifyStyle?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("背景样式")).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(BeautifyStyle.allCases) { style in
                    Button { choose(style) } label: {
                        VStack(spacing: 4) {
                            VideoBackgroundSample(style: style).frame(height: 24)
                            Text(style.title).font(.system(size: 12)).lineLimit(1)
                        }.padding(6).frame(maxWidth: .infinity)
                    }.buttonStyle(StudioNavigationStyle(selected: selected == style))
                        .focused($focused, equals: style).focusEffectDisabled()
                        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.controlRadius)
                            .strokeBorder(selected == style ? Palette.ice : .clear, lineWidth: 1.5).allowsHitTesting(false))
                        .accessibilityLabel(style.title).accessibilityAddTraits(selected == style ? .isSelected : [])
                }
            }
        }.padding(12).frame(width: 300).foregroundStyle(Palette.white).background(Palette.paper)
            .defaultFocus($focused, selected)
            .onKeyPress(.leftArrow) { moveFocus(by: -1); return .handled }
            .onKeyPress(.rightArrow) { moveFocus(by: 1); return .handled }
            .onKeyPress(.upArrow) { moveFocus(by: -3); return .handled }
            .onKeyPress(.downArrow) { moveFocus(by: 3); return .handled }
    }
    private func moveFocus(by offset: Int) {
        let styles = BeautifyStyle.allCases
        let index = styles.firstIndex(of: focused ?? selected) ?? 0, target = index + offset
        guard styles.indices.contains(target) else { return }
        focused = styles[target]
    }
}

private struct VideoBackgroundSample: View {
    let style: BeautifyStyle
    var body: some View {
        // Video uses first/last colors, unlike the image beautifier's three-stop
        // gradient. Keep the palette cue aligned with that existing renderer.
        let colors = style.colors
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [colors.first!, colors.last!].map {
                Color(nsColor: $0.usingColorSpace(.deviceRGB) ?? $0)
            }, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.separator.opacity(0.6)))
            .accessibilityHidden(true)
    }
}
