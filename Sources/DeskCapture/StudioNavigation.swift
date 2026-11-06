import SwiftUI

/// Media remains unmodified; keyboard focus and press feedback sit over the preview.
struct StudioMediaButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Palette.chrome.opacity(enabled && configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(focused ? Palette.ice : .clear, lineWidth: 2).padding(2)
                    .allowsHitTesting(false)
            }
    }
}

/// Navigation uses the same quiet selected, pointer and keyboard states in every studio.
struct StudioNavigationStyle: ButtonStyle {
    var selected = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: StudioMetrics.controlRadius, style: .continuous)
        configuration.label
            .foregroundStyle(selected ? Palette.ice : Palette.white)
            .background(selected ? Palette.selection : (enabled && hovered ? Palette.controlHover : .clear), in: shape)
            .overlay(shape.fill(Palette.chrome.opacity(enabled && configuration.isPressed ? 0.08 : 0)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(focused ? Palette.ice : (selected && contrast == .increased ? Palette.ice : .clear),
                                       lineWidth: focused ? 2 : 1).allowsHitTesting(false))
            .contentShape(shape).opacity(enabled ? 1 : 0.4)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// Window-local tool navigation. Buttons preserve normal Tab/Space activation;
/// arrows move within the strip without changing the window's first responder elsewhere.
struct StudioToolTabs<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let symbol: (Value) -> String
    @FocusState private var focused: Value?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button { selection = item } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(item)).font(.system(size: 13)).accessibilityHidden(true)
                        Text(title(item)).font(.system(size: 12, weight: selection == item ? .semibold : .medium))
                            .lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(StudioNavigationStyle(selected: selection == item))
                .focused($focused, equals: item).focusEffectDisabled()
                .accessibilityLabel(title(item)).accessibilityAddTraits(selection == item ? .isSelected : [])
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
                .help(index < 9 ? L10n.text("\(title(item)) · ⌘\(index + 1)") : title(item))
                .onKeyPress(.leftArrow) { move(from: index, by: -1); return .handled }
                .onKeyPress(.rightArrow) { move(from: index, by: 1); return .handled }
            }
        }.padding(8).accessibilityElement(children: .contain)
    }
    private func move(from index: Int, by offset: Int) {
        let item = items[min(max(index + offset, 0), items.count - 1)]
        selection = item; focused = item
    }
}
