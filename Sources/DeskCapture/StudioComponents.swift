import SwiftUI
import AppKit

/// UI chrome only: captured pixels and exported media retain their original colors.
struct StudioHeader: View {
    let title: String
    var symbol = "viewfinder"
    var compact = false
    var body: some View {
        HStack(spacing: 10) {
            if symbol == "viewfinder" {
                ViewfinderMark(size: 26)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(Palette.ice)
                    .frame(width: 24, height: 26).accessibilityHidden(true)
            }
            Text(title).font(.system(size: compact ? 17 : 20, weight: .semibold))
                .lineLimit(1).help(title).accessibilityAddTraits(.isHeader)
        }.foregroundStyle(Palette.white)
    }
}

struct StudioSection<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.white)
                .accessibilityAddTraits(.isHeader)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .modifier(StudioPaperSurface())
    }
}

struct StudioEmptyArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 48, style: .continuous).fill(Palette.selection.opacity(0.45))
                .frame(width: 154, height: 154).rotationEffect(.degrees(-7))
            CaptureKeepsakeArtwork(size: 150)
            Image(systemName: "sparkle").font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.apricot).offset(x: 67, y: -51)
            Circle().fill(Palette.sage.opacity(0.65)).frame(width: 6, height: 6).offset(x: -68, y: 31)
        }.frame(width: 190, height: 190).accessibilityHidden(true)
    }
}


/// A quiet paper edge, shared by forms and media workspaces. This styles UI
/// surfaces only and never enters image processing or output rendering.
struct StudioPaperSurface: ViewModifier {
    var radius: CGFloat = StudioMetrics.groupRadius
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(contrast == .increased ? Palette.separator : Palette.chrome.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
