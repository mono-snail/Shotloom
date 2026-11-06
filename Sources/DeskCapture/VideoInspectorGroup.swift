import SwiftUI

/// A single functional group, shared by the video inspector's primary and advanced controls.
struct InspectorGroup<Content: View>: View {
    let title: String
    private let externalExpansion: Binding<Bool>?
    @State private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, expanded: Binding<Bool>? = nil, initiallyExpanded: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title; externalExpansion = expanded
        _expanded = State(initialValue: initiallyExpanded); self.content = content
    }

    var body: some View {
        let expansion = externalExpansion ?? $expanded
        VStack(alignment: .leading, spacing: 8) {
            Button { expansion.wrappedValue.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expansion.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(width: 12).accessibilityHidden(true)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 6).frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(StudioNavigationStyle())
                .accessibilityLabel(title).accessibilityValue(expansion.wrappedValue ? L10n.text("已展开") : L10n.text("已折叠"))
                .onKeyPress(.rightArrow) {
                    guard !expansion.wrappedValue else { return .ignored }
                    expansion.wrappedValue = true; return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard expansion.wrappedValue else { return .ignored }
                    expansion.wrappedValue = false; return .handled
                }
            if expansion.wrappedValue {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 12)
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
    }
}

/// Video parameters have a fixed two-column rhythm; lists keep their own rows.
struct VideoInspectorGroup<Content: View>: View {
    let title: String
    var grid = true
    private let externalExpansion: Binding<Bool>?
    @State private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, expanded: Binding<Bool>? = nil, initiallyExpanded: Bool = false,
         grid: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.grid = grid; externalExpansion = expanded
        _expanded = State(initialValue: initiallyExpanded); self.content = content
    }
    var body: some View {
        InspectorGroup(title, expanded: externalExpansion ?? $expanded) {
            if grid { VideoControlGrid { content() } } else { content() }
        }
    }
}
