import AppKit
import SwiftUI

struct SavedAnnotationStyle: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tool: AnnotationTool
    var rgba: [Double]
    var width: CGFloat
    var fontSize: CGFloat
    var fill: AnnotationFill
    var textStyle: AnnotationTextStyle
    var mosaicStyle: MosaicStyle
    var mosaicStrength: CGFloat
    var curvature: CGFloat
    var fontName: String?
    var icon: VectorIcon?
    var iconSize: CGFloat?
    var opacity: CGFloat
    @MainActor init(name: String, tool: AnnotationTool, document: AnnotationDocument) {
        self.name = name; self.tool = tool
        let color = (document.customColor ?? document.color.color).usingColorSpace(.sRGB) ?? .systemRed
        rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        width = document.lineWidth; fontSize = document.fontSize; fill = document.fill
        textStyle = document.textStyle; mosaicStyle = document.mosaicStyle; mosaicStrength = document.mosaicStrength
        curvature = document.curvature; opacity = document.opacity; icon = document.icon; iconSize = document.iconSize; fontName = document.fontName
    }
    var valid: Bool {
        rgba.count == 4 && rgba.allSatisfy { $0.isFinite && (0...1).contains($0) }
        && width.isFinite && (2...20).contains(width) && fontSize.isFinite && (8...200).contains(fontSize)
        && mosaicStrength.isFinite && (1...20).contains(mosaicStrength) && curvature.isFinite && abs(curvature) <= 1
        && opacity.isFinite && (0...1).contains(opacity)
    }
    @MainActor func apply(to document: AnnotationDocument) {
        guard valid else { return }
        // A preset configures the next mark; applying it never silently changes existing marks.
        document.selectMark(at: CGPoint(x: -1, y: -1), tolerance: .zero)
        document.customColor = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        document.lineWidth = width; document.fontSize = fontSize; document.fill = fill
        document.textStyle = textStyle; document.mosaicStyle = mosaicStyle; document.mosaicStrength = mosaicStrength
        document.curvature = curvature; document.opacity = opacity; document.tool = tool
        document.fontName = fontName ?? ""
        if let icon { document.icon = icon }; if let iconSize, iconSize.isFinite { document.iconSize = min(180, max(24, iconSize)) }
    }
}

@MainActor
final class AnnotationPresetStore: ObservableObject {
    static let shared = AnnotationPresetStore()
    @Published private(set) var colors: [String]
    @Published private(set) var styles: [SavedAnnotationStyle]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppPreferences.standard) {
        self.defaults = defaults
        colors = Array((defaults.stringArray(forKey: "favoriteColors") ?? []).filter { Self.color($0) != nil }.prefix(12))
        styles = Array(((defaults.data(forKey: "annotationStyles").flatMap { try? JSONDecoder().decode([SavedAnnotationStyle].self, from: $0) }) ?? []).filter(\.valid).prefix(20))
    }
    static func color(_ hex: String) -> NSColor? {
        guard hex.count == 7, hex.first == "#", hex.dropFirst().allSatisfy({ "0123456789abcdefABCDEF".contains($0) }), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    func addColor(_ hex: String) {
        let value = hex.uppercased(); guard Self.color(value) != nil else { return }
        colors.removeAll { $0 == value }; colors.insert(value, at: 0); colors = Array(colors.prefix(12))
        defaults.set(colors, forKey: "favoriteColors")
    }
    func removeColor(_ hex: String) { colors.removeAll { $0 == hex }; defaults.set(colors, forKey: "favoriteColors") }
    func replacePalette(_ values: [String]) {
        guard values.count <= 12, values.allSatisfy({ Self.color($0) != nil }) else { return }
        colors = values.map { $0.uppercased() }; defaults.set(colors, forKey: "favoriteColors")
    }
    func save(_ style: SavedAnnotationStyle) {
        guard style.valid else { return }
        styles.removeAll { $0.name == style.name }; styles.insert(style, at: 0); styles = Array(styles.prefix(20)); persist()
    }
    func remove(_ id: UUID) { styles.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: "annotationStyles") } }
}
