// Development-only fixture: exercises the real overlay without screen permissions.
import AppKit

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    var session: SelectionSession?
    var coordinator: AppCoordinator?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let width = Int(screen.frame.width * screen.backingScaleFactor)
        let height = Int(screen.frame.height * screen.backingScaleFactor)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        let card = CGRect(x: CGFloat(width) * 0.24, y: CGFloat(height) * 0.40, width: CGFloat(width) * 0.52, height: CGFloat(height) * 0.32)
        NSColor(white: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28).fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .semibold), .foregroundColor: NSColor.black]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.darkGray]
        ("框选 · 现场标注 · 双击复制" as NSString).draw(at: CGPoint(x: card.minX + 65, y: card.maxY - 140), withAttributes: title)
        ("这是一张开发验证画面，不是真实桌面。" as NSString).draw(at: CGPoint(x: card.minX + 65, y: card.maxY - 220), withAttributes: body)
        ("剪贴板优先，让截图回到流畅。" as NSString).draw(at: CGPoint(x: card.minX + 65, y: card.maxY - 290), withAttributes: body)
        NSColor(calibratedRed: 0.2, green: 0.65, blue: 0.8, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: card.minX + 65, y: card.minY + 65, width: 350, height: 100), xRadius: 18, yRadius: 18).fill()
        NSGraphicsContext.restoreGraphicsState()
        let region = CGRect(x: screen.frame.width * 0.25, y: CommandLine.arguments.contains("--bottom") ? 60 : screen.frame.height * 0.41,
                            width: screen.frame.width * 0.50, height: screen.frame.height * 0.30)
        let board = NSPasteboard(name: .init("Shotloom.ToolbarReview"))
        let session = SelectionSession(snapshots: [ScreenSnapshot(screen: screen, image: bitmap.cgImage!)], windows: [], mode: .region, previewRect: region, colorPasteboard: board)
        guard let home = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] else { return }
        let store = CaptureStore(directory: URL(fileURLWithPath: home).appendingPathComponent("history"),
                                 pruneOnInit: false, automaticRecovery: false)
        let coordinator = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        self.coordinator = coordinator
        session.onComplete = { [weak coordinator] image, destination, _ in
            // Use the production workflow entry point, with this fixture's
            // synthetic image and isolated preferences/history/clipboard.
            switch destination {
            case .configureWorkflow: coordinator?.showWorkflow(source: image)
            case .workflow(let id): coordinator?.showWorkflow(id: id, source: image, runOnOpen: true)
            default: NSApp.terminate(nil)
            }
        }
        session.onCancel = { print("PREVIEW cancelled"); NSApp.terminate(nil) }
        self.session = session
        NSApp.activate(ignoringOtherApps: true); session.show()
    }
}

@main
enum InteractionPreview {
    @MainActor static func main() {
        guard ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"]?.hasPrefix("/tmp/deskcapture-ui-store-") == true else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate(); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
