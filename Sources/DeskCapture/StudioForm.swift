import SwiftUI

private struct CompactInspectorControlsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var compactInspectorControls: Bool {
        get { self[CompactInspectorControlsKey.self] }
        set { self[CompactInspectorControlsKey.self] = newValue }
    }
}

/// Shared two-column inspector layout; fields keep their title and accessibility label.
struct InspectorControlGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) { content() }
    }
}

/// A label and its control stay together at every inspector width.
struct InspectorField<Content: View>: View {
    @Environment(\.compactInspectorControls) private var compact
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : StudioMetrics.fieldSpacing) {
            Text(title).font(.system(size: compact ? 12 : 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            content().labelsHidden().frame(maxWidth: .infinity, minHeight: compact ? 26 : 32, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Unlike the system switch layout, this keeps the switch at the trailing edge of a form.
struct InspectorToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            Button { configuration.isOn.toggle() } label: {
                configuration.label.fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).focusable(false).accessibilityHidden(true)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

/// Text and list dialogs share stable chrome; their content owns its scrolling.
struct StudioDialog<Content: View, Actions: View>: View {
    let title: String
    let symbol: String
    var width: CGFloat = 560
    var height: CGFloat = 560
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StudioHeader(title: title, symbol: symbol, compact: true)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, StudioMetrics.contentInset).padding(.vertical, 14)
                .frame(minHeight: StudioMetrics.barHeight).background(Palette.paper)
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(StudioMetrics.contentInset)
            Divider()
            StudioActionBar { actions() }
        }.frame(minWidth: width, idealWidth: width, maxWidth: .infinity,
                minHeight: height, idealHeight: height, maxHeight: .infinity)
            .font(.system(size: 13)).foregroundStyle(Palette.white)
            .textFieldStyle(.roundedBorder).toggleStyle(InspectorToggleStyle())
            .controlSize(.small).tint(Palette.ice).background(Palette.ink)
            .buttonStyle(StudioButtonStyle(command: true))
    }
}

struct BackgroundSwatches: View {
    @Binding var selection: BeautifyStyle
    var showsSelection = true
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 32), spacing: 8), count: 6), spacing: 8) {
            ForEach(BeautifyStyle.allCases) { style in
                BackgroundSwatch(style: style, selected: showsSelection && selection == style) { selection = style }
            }
        }
    }
}

private struct BackgroundSwatch: View {
    let style: BeautifyStyle
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: style.colors.map { Color(nsColor: $0) },
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.chrome.opacity(contrast == .increased ? 0.45 : 0.10)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.chrome.opacity(hovered && enabled ? 0.08 : 0)))
                .frame(height: 30).padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Palette.ice : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                            .foregroundStyle(Palette.onAccent, Palette.ice)
                            .font(.system(size: 12, weight: .semibold)).padding(4).accessibilityHidden(true)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(focused ? Palette.ice : .clear, lineWidth: 2).padding(-2))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }.buttonStyle(StudioSurfacePressStyle(radius: 9)).help(style.title).accessibilityLabel(style.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .focused($focused).focusEffectDisabled().onHover { hovered = $0 }
    }
}
