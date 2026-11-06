import SwiftUI

private struct VideoInspectorFieldsKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var videoInspectorFields: Bool {
        get { self[VideoInspectorFieldsKey.self] }
        set { self[VideoInspectorFieldsKey.self] = newValue }
    }
}

/// All parameter sections use the same two columns, including expanded controls.
struct VideoControlGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .topLeading),
                            GridItem(.flexible(), spacing: 16, alignment: .topLeading)],
                  alignment: .leading, spacing: 20) { content() }
    }
}

struct VideoField<Content: View>: View {
    let title: String
    var value: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(title)
                if let value {
                    Spacer(minLength: 0)
                    Text(value).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.muted)
                        .fixedSize().accessibilityHidden(true)
                }
            }.frame(height: StudioMetrics.videoFieldTitleHeight, alignment: .topLeading)
            content().labelsHidden().frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct VideoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.system(size: 13, weight: .medium))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(height: StudioMetrics.videoFieldTitleHeight, alignment: .topLeading).accessibilityHidden(true)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch).labelsHidden()
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
