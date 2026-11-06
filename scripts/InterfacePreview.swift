// Render the production SwiftUI views without capturing the desktop.
import AppKit
import SwiftUI

@MainActor
final class InterfacePreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = AppCoordinator()
        let directory = URL(fileURLWithPath: "/tmp/deskcapture-interface-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance, notice) in [
            ("launcher-light", NSAppearance.Name.aqua, Optional<String>.none),
            ("launcher-dark", .darkAqua, nil),
            ("launcher-notice", .aqua, "屏幕捕获权限尚未开启。请前往系统设置允许 DeskCapture 捕获屏幕，然后重新截图。")
        ] {
            NSApp.appearance = NSAppearance(named: appearance)
            app.notice = notice
            render(CompactLauncherView(app: app, store: app.store), size: nil, name: name, directory: directory)
        }
        app.notice = nil
        for (name, appearance, state) in [
            ("menu-light", NSAppearance.Name.aqua, StatusMenuState(canRepeat: true, screenCount: 2)),
            ("menu-dark", .darkAqua, StatusMenuState(canRepeat: true, screenCount: 2)),
            ("menu-recording", .aqua, StatusMenuState(recording: .recording, elapsed: 83)),
            ("menu-paused", .darkAqua, StatusMenuState(recording: .paused, elapsed: 83)),
            ("menu-finishing", .aqua, StatusMenuState(recording: .finishing, elapsed: 83)),
            ("menu-scrolling", .aqua, StatusMenuState(scrolling: true)),
            ("menu-scrolling-busy", .aqua, StatusMenuState(scrolling: true, scrollingBusy: true))
        ] {
            NSApp.appearance = NSAppearance(named: appearance)
            render(StatusMenuView(app: app, previewState: state, perform: { _ in }, close: {}), size: nil, name: name, directory: directory)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        render(HistoryView(app: app, store: CaptureStore(directory: directory.appendingPathComponent("empty-history"))), size: CGSize(width: 760, height: 500), name: "history-light", directory: directory)
        for (name, appearance) in [("settings-light", NSAppearance.Name.aqua), ("settings-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            render(SettingsView(app: app), size: CGSize(width: 840, height: 680), name: name, directory: directory)
        }
        for section in [SettingsSection.shortcuts, .toolbar] {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                render(SettingsView(app: app, initialSection: section), size: CGSize(width: 840, height: 680),
                       name: "settings-\(section == .shortcuts ? "shortcuts" : "toolbar")-\(suffix)", directory: directory)
            }
        }
        let gallery = CaptureStore(directory: directory.appendingPathComponent("gallery-\(UUID())"))
        var firstRecord: CaptureRecord?
        var firstImage: CGImage?
        for (index, color) in [NSColor.systemBlue, .systemIndigo, .systemOrange].enumerated() {
            if let image = fixture(color: color, index: index), let record = try? gallery.add(image, mode: .region) {
                firstRecord = record; firstImage = image
            }
        }
        for (name, appearance) in [("gallery-light", NSAppearance.Name.aqua), ("gallery-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            render(HistoryView(app: app, store: gallery), size: CGSize(width: 820, height: 650), name: name, directory: directory)
        }
        if let firstRecord, let firstImage {
            let parent = NSWindow()
            NSApp.appearance = NSAppearance(named: .aqua)
            render(EditorView(app: app, store: gallery, document: AnnotationDocument(image: firstImage), record: firstRecord, parent: parent), size: CGSize(width: 1100, height: 720), name: "image-editor-light", directory: directory)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            render(EditorView(app: app, store: gallery, document: AnnotationDocument(image: firstImage), record: firstRecord, parent: parent), size: CGSize(width: 1100, height: 720), name: "image-editor-dark", directory: directory)
        }
        for (name, appearance) in [("guide-light", NSAppearance.Name.aqua), ("guide-dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            render(StatusItemGuideView(tipX: 192, open: {}, close: {}), size: StatusGuideGeometry.size, name: name, directory: directory)
        }
        render(HStack(spacing: 24) {
            CaptureEntryArtwork(active: true).background(Palette.ice)
            CaptureGlyph(kind: .text, tint: OpticalPalette.violet, size: 50, active: true)
            CaptureGlyph(kind: .scrolling, size: 50, active: true)
            CaptureGlyph(kind: .recording, tint: OpticalPalette.coral, size: 50, active: true)
        }.padding(20).background(Palette.ink), size: CGSize(width: 360, height: 120), name: "glyphs-active", directory: directory)
        print("Interface previews: \(directory.path)")
        NSApp.terminate(nil)
    }
    func fixture(color: NSColor, index: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(color.withAlphaComponent(0.12).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 960, height: 600))
        ctx.setStrokeColor(color.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(2)
        for i in 0..<5 { ctx.strokeEllipse(in: CGRect(x: 470 - i * 32, y: 140 - i * 32, width: 240 + i * 64, height: 240 + i * 64)) }
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 60, y: 70, width: 160, height: 5))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let titles = ["留住灵感", "让细节发光", "每一帧，都值得"]
        (titles[index] as NSString).draw(at: NSPoint(x: 60, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: color])
        ("DeskCapture / 光学工作台" as NSString).draw(at: NSPoint(x: 60, y: 355), withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
    func render<V: View>(_ view: V, size: CGSize?, name: String, directory: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size ?? CGSize(width: 328, height: 398)), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(size ?? host.fittingSize)
        window.orderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        print("\(name): \(host.bounds.size)")
        window.orderOut(nil)
    }
}
@main enum InterfacePreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = InterfacePreviewDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
