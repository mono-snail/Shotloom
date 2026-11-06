import SwiftUI

/// Keep an explicit disclosure cue when native menus use the shared command surface.
struct StudioMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }
    var body: some View {
        Menu(content: content) {
            HStack(spacing: 7) {
                Text(title)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted).accessibilityHidden(true)
            }
        }.menuIndicator(.hidden).buttonStyle(StudioButtonStyle(command: true))
            .accessibilityLabel(title)
    }
}

/// A heading and its commands keep their own alignment when space is scarce.
struct StudioToolbar<Heading: View, Tools: View>: View {
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let tools: () -> Tools
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                heading().fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 16)
                HStack(spacing: 8) { tools() }.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                heading().frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { tools() }.fixedSize(horizontal: true, vertical: false)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13)).controlSize(.small)
        .buttonStyle(StudioButtonStyle(command: true))
        .padding(.horizontal, StudioMetrics.contentInset).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: StudioMetrics.barHeight, alignment: .leading).background(Palette.paper)
        // Commands determine the bar's height; extra window height belongs to the canvas.
        .fixedSize(horizontal: false, vertical: true)
    }
}
