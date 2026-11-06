import SwiftUI

// The capture controls share one optical language; the image itself is never styled.
enum OpticalPalette {
    static let cyan = Palette.ice
    static let violet = Color(red: 0.55, green: 0.45, blue: 0.79)
    static let coral = Color(red: 0.96, green: 0.49, blue: 0.41)
}

struct OpticalGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 6) { content() } }
        else { content() }
    }
}

struct OpticalLens: ViewModifier {
    var tint: Color = OpticalPalette.cyan
    var radius: CGFloat = 18
    var interactive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        material(content)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(stops: [
                        .init(color: .white.opacity(scheme == .dark ? 0.65 : 0.95), location: 0),
                        .init(color: tint.opacity(0.55), location: 0.24),
                        .init(color: Palette.chrome.opacity(contrast == .increased ? 0.45 : 0.08), location: 0.5),
                        .init(color: tint.opacity(0.35), location: 0.77),
                        .init(color: .white.opacity(0.45), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1.5 : 0.8)
                    .allowsHitTesting(false)
            }
    }
    @ViewBuilder private func material(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if solid { content.background(Palette.ink, in: shape) }
        else if #available(macOS 26, *) { content.glassEffect(.regular.tint(tint.opacity(scheme == .dark ? 0.15 : 0.08)).interactive(interactive), in: shape) }
        else {
            content.background {
                shape.fill(Palette.chrome.opacity(scheme == .dark ? 0.075 : 0.045))
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.16), tint.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
        }
    }
}

struct OpticalButtonStyle: ButtonStyle {
    var tint: Color = OpticalPalette.cyan
    var radius: CGFloat = 18
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(OpticalLens(tint: tint, radius: radius, interactive: enabled))
            .overlay(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(configuration.isPressed ? 0.18 : hovering ? 0.08 : 0)).allowsHitTesting(false))
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.985 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.16), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct OpticalPanel: View {
    var radius: CGFloat = 24
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid
    var body: some View {
        ZStack {
            if !solid { GlassMaterial() }
            Palette.ink.opacity(solid ? 1 : scheme == .dark ? 0.86 : 0.94)

        }.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.65), Palette.chrome.opacity(0.08), OpticalPalette.cyan.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            .allowsHitTesting(false)
    }
}

// Filled primary action, restrained secondary surfaces, and shared pointer feedback.
struct StudioButtonStyle: ButtonStyle {
    var primary = false
    var radius: CGFloat = 10
    var quiet = false
    var accentHover = false
    var command = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .fixedSize(horizontal: command, vertical: false)
            .padding(.horizontal, command ? 12 : 0)
            .frame(minHeight: command ? StudioMetrics.iconTarget : nil)
            .foregroundStyle(configuration.role == .destructive ? Color.red : (primary ? Palette.onAccent : Palette.white))
            .background {
                if primary { shape.fill(Palette.ice) }
                else { shape.fill(quiet ? Color.clear : Palette.paper) }
            }
            .overlay(shape.fill((primary ? Palette.onAccent : (accentHover ? Palette.ice : Palette.chrome)).opacity(
                enabled ? (configuration.isPressed ? 0.12 : hovering ? (accentHover ? 0.10 : 0.065) : 0) : 0)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(Palette.chrome.opacity(contrast == .increased ? 0.4 : primary || quiet ? 0 : 0.07))
                .allowsHitTesting(false))
            .overlay {
                if focused {
                    shape.strokeBorder(primary ? Palette.onAccent : Palette.ice, lineWidth: 2)
                        .padding(primary ? 3 : 0).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.4)
            // A command changes surface, not geometry; text stays sharp while pressed.
            .animation(reducedMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}
