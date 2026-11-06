import SwiftUI

/// Shared layout for image tools: a stable action bar, canvas, inspector and delivery bar.
struct StudioWorkspace<Tools: View, Preview: View, Inspector: View, Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let tools: () -> Tools
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let inspector: () -> Inspector
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar { heading } tools: { tools() }
            Divider()
            HSplitView {
                preview().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(StudioMetrics.contentInset).frame(minWidth: 420).background(Palette.canvas)
                ScrollView {
                    VStack(alignment: .leading, spacing: StudioMetrics.sectionSpacing) { inspector() }
                        .toggleStyle(InspectorToggleStyle()).textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(StudioMetrics.contentInset)
                }.scrollBounceBehavior(.basedOnSize)
                    .frame(minWidth: StudioMetrics.inspectorMinimum, idealWidth: StudioMetrics.inspectorIdeal,
                        maxWidth: StudioMetrics.inspectorMaximum).background(Palette.paper)
            }
            Divider()
            StudioActionBar { actions() }
        }
        .font(.system(size: 13)).foregroundStyle(Palette.white)
        .toggleStyle(.switch).controlSize(.small).tint(Palette.ice)
        .buttonStyle(StudioButtonStyle(command: true))
        .frame(minWidth: StudioMetrics.workspaceMinimum.width, minHeight: StudioMetrics.workspaceMinimum.height).background(Palette.ink)
    }
    private var heading: some View {
        StudioHeader(title: title, symbol: symbol, compact: true)
            .lineLimit(1).help(title).accessibilityAddTraits(.isHeader)
    }
}

/// SF Symbols can choose a script using the OS language rather than L10n.
/// Keep the English text-tool glyph independent of the user's system language.
struct StudioSymbol: View {
    let name: String
    var body: some View {
        if name == "textformat" && L10n.language == AppLanguage.english.rawValue {
            Text(verbatim: "Aa")
        } else {
            Image(systemName: name)
        }
    }
}

struct StudioIconButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var keyboardFocused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: action) {
            StudioSymbol(name: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: StudioMetrics.iconTarget, height: StudioMetrics.iconTarget)
                .foregroundStyle(selected ? Palette.ice : Palette.white)
                .background(selected ? Palette.selection : (hovered && enabled ? Palette.controlHover : .clear),
                            in: RoundedRectangle(cornerRadius: StudioMetrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: StudioMetrics.controlRadius)
                    .strokeBorder(keyboardFocused ? Palette.ice : (selected && contrast == .increased ? Palette.ice : .clear),
                                  lineWidth: keyboardFocused ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: StudioMetrics.controlRadius))
                .symbolRenderingMode(.hierarchical)
        }.buttonStyle(StudioSurfacePressStyle()).opacity(enabled ? 1 : 0.4).help(title).accessibilityLabel(title)
            .focused($keyboardFocused).focusEffectDisabled()
            .accessibilityAddTraits(selected ? .isSelected : []).onHover { hovered = $0 }
    }
}

/// Press feedback for visual choices and icons, without resizing their contents.
struct StudioSurfacePressStyle: ButtonStyle {
    var radius: CGFloat = StudioMetrics.controlRadius
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Palette.chrome.opacity(enabled && configuration.isPressed ? 0.12 : 0))
                .allowsHitTesting(false))
            .animation(reducedMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
