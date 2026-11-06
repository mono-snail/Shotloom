import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: L10n.text("跟随系统"); case .light: L10n.text("浅色"); case .dark: L10n.text("深色") } }
    @MainActor static func apply(_ value: String) {
        let mode = AppAppearance(rawValue: value) ?? .system
        NSApp.appearance = switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Palette {
    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let ice = Color(nsColor: StudioNativeColor.accent)
    static let ink = adaptive("DeskCapture.surface", light: NSColor(calibratedRed: 0.957, green: 0.953, blue: 0.944, alpha: 1),
                             dark: NSColor(calibratedRed: 0.09, green: 0.094, blue: 0.106, alpha: 1))
    static let paper = Color(nsColor: StudioNativeColor.paper)
    static let canvas = Color(nsColor: StudioNativeColor.canvas)
    static let white = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let chrome = adaptive("DeskCapture.chrome", light: .black, dark: .white)
    static let separator = Color(nsColor: .separatorColor)
    static let controlHover = chrome.opacity(0.07)
    static let selection = ice.opacity(0.13)
    // Small illustration accents; functional states continue to use semantic colors.
    static let sage = adaptive("DeskCapture.sage", light: NSColor(calibratedRed: 0.38, green: 0.62, blue: 0.51, alpha: 1),
                              dark: NSColor(calibratedRed: 0.55, green: 0.76, blue: 0.65, alpha: 1))
    static let apricot = adaptive("DeskCapture.apricot", light: NSColor(calibratedRed: 0.91, green: 0.59, blue: 0.40, alpha: 1),
                                 dark: NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.51, alpha: 1))
    static let onAccent = adaptive("DeskCapture.onAccent", light: .white,
                                  dark: NSColor(calibratedRed: 0.075, green: 0.082, blue: 0.17, alpha: 1))
}

enum StudioNativeColor {
    static let canvas = NSColor(name: "DeskCapture.nativeCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.066, green: 0.070, blue: 0.081, alpha: 1)
            : NSColor(calibratedRed: 0.938, green: 0.936, blue: 0.929, alpha: 1)
    }
    static let paper = NSColor(name: "DeskCapture.nativePaper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.128, green: 0.133, blue: 0.149, alpha: 1)
            : NSColor(calibratedRed: 0.997, green: 0.994, blue: 0.984, alpha: 1)
    }
    static let accent = NSColor(name: "DeskCapture.nativeAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.73, green: 0.70, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.35, green: 0.30, blue: 0.73, alpha: 1)
    }
}
