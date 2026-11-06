import AppKit
import SwiftUI

/// Built-in combinations use the existing renderer. They preserve the chosen
/// canvas ratio and do not write or replace the user's personal presets.
enum BeautifyLook: String, CaseIterable, Identifiable {
    case clear, paper, graphite, aurora
    var id: Self { self }
    var title: String {
        switch self { case .clear: L10n.text("清透"); case .paper: L10n.text("暖纸"); case .graphite: L10n.text("石墨"); case .aurora: L10n.text("极光") }
    }
    var style: BeautifyStyle {
        switch self { case .clear: .frost; case .paper: .paper; case .graphite: .graphite; case .aurora: .aurora }
    }
    var padding: Double {
        switch self { case .clear: 0.10; case .paper: 0.14; case .graphite: 0.12; case .aurora: 0.09 }
    }
    var roundness: Double {
        switch self { case .clear: 0.18; case .paper: 0.32; case .graphite: 0.22; case .aurora: 0.27 }
    }
    func matches(style: BeautifyStyle, padding: Double, roundness: Double) -> Bool {
        self.style == style && abs(self.padding - padding) < 0.00001 && abs(self.roundness - roundness) < 0.00001
    }
    static func available(for source: CGImage, layout: BeautifyLayout) -> [Self] {
        allCases.filter { (try? CaptureBeautifier.geometry(width: source.width, height: source.height,
            paddingPercent: $0.padding, layout: layout)) != nil }
    }
}

struct BeautifyLookPicker: View {
    let source: CGImage
    let layout: BeautifyLayout
    let selected: BeautifyLook?
    let apply: (BeautifyLook) -> Void
    @State private var previews: [BeautifyLook: CGImage] = [:]
    private struct RenderKey: Hashable {
        let source: ObjectIdentifier
        let layout: String
    }
    private var renderKey: RenderKey { .init(source: ObjectIdentifier(source), layout: layout.rawValue) }
    private var looks: [BeautifyLook] { BeautifyLook.available(for: source, layout: layout) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(looks) { look in
                Button { apply(look) } label: {
                    VStack(spacing: 5) {
                        Group {
                            if let image = previews[look] {
                                Image(decorative: image, scale: 1).resizable().scaledToFit()
                            } else {
                                Image(systemName: "photo").foregroundStyle(Palette.muted).accessibilityHidden(true)
                            }
                        }.frame(maxWidth: .infinity).frame(height: 56)
                            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
                        Text(look.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }.padding(6).frame(maxWidth: .infinity)
                }.buttonStyle(StudioNavigationStyle(selected: selected == look))
                    .overlay(RoundedRectangle(cornerRadius: StudioMetrics.controlRadius)
                        .strokeBorder(selected == look ? Palette.ice : .clear, lineWidth: 1.5).allowsHitTesting(false))
                    .accessibilityLabel(L10n.text("应用\(look.title)风格")).accessibilityAddTraits(selected == look ? .isSelected : [])
                    .help(look.title)
            }
        }
        .task(id: renderKey) {
            let key = renderKey, input = source, selectedLayout = layout, choices = looks
            previews = [:]
            let worker = Task.detached(priority: .utility) { () throws -> [BeautifyLook: CGImage] in
                var images: [BeautifyLook: CGImage] = [:]
                for look in choices {
                    try Task.checkCancellation()
                    if let image = try? CaptureBeautifier.render(input, style: look.style, paddingPercent: look.padding,
                        roundness: look.roundness, layout: selectedLayout, maximumDimension: 240) {
                        images[look] = image
                    }
                }
                try Task.checkCancellation()
                return images
            }
            do {
                let images = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, key == renderKey else { return }
                previews = images
            } catch { /* The main canvas reports any render failure when selected. */ }
        }
    }
}
