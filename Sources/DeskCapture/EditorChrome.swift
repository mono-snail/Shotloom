import SwiftUI

/// Editor chrome only. Bindings keep their existing units, ranges and callbacks.
struct EditorBarTitle: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).help(detail)
                .lineLimit(1).truncationMode(.middle)
        }.foregroundStyle(Palette.white)
    }
}

struct EditorInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.white)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }
}

struct InspectorSlider: View {
    @Environment(\.compactInspectorControls) private var compact
    @Environment(\.videoInspectorFields) private var videoFields
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var scale: Double = 1
    var unit = ""
    var decimals = 0
    private var display: String { String(format: "%.*f", decimals, value * scale) + unit }
    @ViewBuilder var body: some View {
        if videoFields {
            VideoField(title: title, value: display) {
                Slider(value: $value, in: range).accessibilityLabel(title).accessibilityValue(display)
            }
        } else {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.medium)
                    Spacer(minLength: 4)
                    Text(display).monospacedDigit().foregroundStyle(Palette.muted).fixedSize().accessibilityHidden(true)
                }
                Slider(value: $value, in: range)
                    .frame(minHeight: compact ? 26 : nil)
                    .accessibilityLabel(title).accessibilityValue(display)
            }.font(.system(size: compact ? 12 : 13)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct InspectorSliderPair: View {
    @Environment(\.videoInspectorFields) private var videoFields
    let firstTitle: String
    @Binding var first: Double
    let secondTitle: String
    @Binding var second: Double
    var range: ClosedRange<Double> = 0...1
    var scale: Double = 100
    var unit = "%"
    @ViewBuilder var body: some View {
        if videoFields {
            InspectorSlider(title: firstTitle, value: $first, range: range, scale: scale, unit: unit)
            InspectorSlider(title: secondTitle, value: $second, range: range, scale: scale, unit: unit)
        } else {
            HStack(spacing: 16) {
                InspectorSlider(title: firstTitle, value: $first, range: range, scale: scale, unit: unit)
                InspectorSlider(title: secondTitle, value: $second, range: range, scale: scale, unit: unit)
            }
        }
    }
}

struct EditorStatusLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle").foregroundStyle(Palette.ice)
            Text(text).lineLimit(2).textSelection(.enabled).help(text)
            Spacer(minLength: 0)
        }.font(.system(size: 13)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 16).padding(.vertical, 7).background(Palette.ink)
    }
}
