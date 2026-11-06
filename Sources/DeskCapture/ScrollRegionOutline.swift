import AppKit

/// Four narrow, click-through windows keep the chosen region visible without
/// placing an input surface over the page. CaptureEngine excludes our process.
@MainActor
final class ScrollRegionOutline {
    private var panels: [NSPanel] = []
    var isVisible: Bool { panels.count == 4 && panels.allSatisfy(\.isVisible) }
    private(set) var selection: CGRect = .zero

    static func edges(around rect: CGRect, thickness: CGFloat = 2) -> [CGRect] {
        [CGRect(x: rect.minX - thickness, y: rect.minY - thickness, width: rect.width + 2 * thickness, height: thickness),
         CGRect(x: rect.minX - thickness, y: rect.maxY, width: rect.width + 2 * thickness, height: thickness),
         CGRect(x: rect.minX - thickness, y: rect.minY, width: thickness, height: rect.height),
         CGRect(x: rect.maxX, y: rect.minY, width: thickness, height: rect.height)]
    }

    func show(screen: NSScreen, rect: CGRect) {
        close()
        selection = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        for edge in Self.edges(around: selection) {
            let panel = NSPanel(contentRect: edge, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L10n.text("长截图选区边框")
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.backgroundColor = .systemCyan
            panel.isOpaque = true; panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func close() {
        panels.forEach { $0.close() }; panels.removeAll(); selection = .zero
    }
}
