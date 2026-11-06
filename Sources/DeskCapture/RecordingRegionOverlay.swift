import AppKit

/// A live, click-through guide; display recordings exclude this app's windows.
@MainActor
final class RecordingRegionOverlay {
    private(set) var panels: [NSPanel] = []

    func update(bounds: CGRect, screens: [NSScreen] = NSScreen.screens) {
        let frames = screens.map(\.frame).filter { $0.intersects(bounds) }
        if panels.map(\.frame) != frames {
            close()
            panels = frames.map { frame in
                let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = L10n.text("录制区域")
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 2)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.contentView = RecordingRegionOverlayView(frame: CGRect(origin: .zero, size: frame.size))
                return panel
            }
        }
        for panel in panels {
            guard let view = panel.contentView as? RecordingRegionOverlayView else { continue }
            view.recordingRect = bounds.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            panel.orderFrontRegardless()
        }
    }

    func close() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }
}

final class RecordingRegionOverlayView: NSView {
    var recordingRect: CGRect = .zero { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    var maskPath: NSBezierPath {
        let path = NSBezierPath(rect: bounds)
        path.appendRect(recordingRect)
        path.windingRule = .evenOdd
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        maskPath.fill()
        // Draw outside the capture rectangle so the recorded area stays unobscured.
        let border = NSBezierPath(rect: recordingRect.insetBy(dx: -2, dy: -2))
        border.appendRect(recordingRect); border.windingRule = .evenOdd
        NSColor.systemRed.withAlphaComponent(0.9).setFill()
        border.fill()
    }
}
