import SwiftUI

/// Explicit rows keep native controls aligned even inside disclosure groups and popovers.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                Text(title).fontWeight(.medium).fixedSize()
                Spacer(minLength: 8)
                control().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                control().frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .font(.system(size: 13))
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(title, isOn: $isOn).toggleStyle(InspectorToggleStyle())
            .frame(minHeight: 44).font(.system(size: 13, weight: .medium))
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).foregroundStyle(Palette.white)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Palette.muted)
            }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(StudioPaperSurface())
        }
    }
}
