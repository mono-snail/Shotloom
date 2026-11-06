import AppKit
import ScreenCaptureKit

enum WindowBackdrop: String, CaseIterable, Identifiable {
    case transparent, white, black
    var id: String { rawValue }
    var title: String { switch self { case .transparent: L10n.text("透明"); case .white: L10n.text("白色"); case .black: L10n.text("黑色") } }
}

struct CapturePreferences {
    var hideDesktop: Bool
    var windowBackdrop: WindowBackdrop
    var windowShadow: Bool
    init(defaults: UserDefaults = AppPreferences.standard) {
        hideDesktop = defaults.bool(forKey: "hideDesktop")
        windowBackdrop = WindowBackdrop(rawValue: defaults.string(forKey: "windowBackdrop") ?? "transparent") ?? .transparent
        windowShadow = defaults.bool(forKey: "windowShadow")
    }
    static func windowImage(_ source: CGImage, backdrop: WindowBackdrop, shadow: Bool, scale: CGFloat) -> CGImage? {
        let pad = shadow ? max(8, Int(ceil(18 * scale))) : 0
        let w = source.width + pad * 2, h = source.height + pad * 2
        guard w * h <= 80_000_000,
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if backdrop != .transparent {
            c.setFillColor((backdrop == .white ? NSColor.white : .black).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        if shadow { c.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 10 * scale, color: NSColor.black.withAlphaComponent(0.3).cgColor) }
        c.draw(source, in: CGRect(x: pad, y: pad, width: source.width, height: source.height))
        return c.makeImage()
    }
    static func clipboardImage(_ source: CGImage, logicalSize: Bool, backingScale: CGFloat) throws -> CGImage {
        guard logicalSize, backingScale.isFinite, backingScale > 1, backingScale <= 4 else { return source }
        return try CaptureImageTransform.render(source, width: max(1, Int((CGFloat(source.width) / backingScale).rounded())),
                                                height: max(1, Int((CGFloat(source.height) / backingScale).rounded())))
    }
}
