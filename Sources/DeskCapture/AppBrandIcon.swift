import AppKit

/// The capture-corner mascot reduced to a legible monochrome menu-bar mark.
@MainActor
enum AppBrandIcon {
    static func menuBar(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            for (x, y, dx, dy) in [(3.0, 3.0, 1.0, 1.0), (15, 3, -1, 1),
                                    (3, 15, 1, -1), (15, 15, -1, -1)] {
                corners.move(to: NSPoint(x: x, y: y + dy * 3.2))
                corners.line(to: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x + dx * 3.2, y: y))
            }
            corners.stroke()
            NSColor.black.setFill()
            for x in [6.6, 11.4] {
                NSBezierPath(ovalIn: NSRect(x: x - 0.8, y: 9.5, width: 1.6, height: 1.8)).fill()
            }
            let smile = NSBezierPath()
            smile.lineWidth = 1.25
            smile.lineCapStyle = .round
            smile.move(to: NSPoint(x: 6.6, y: 7.4))
            smile.curve(to: NSPoint(x: 11.4, y: 7.4),
                        controlPoint1: NSPoint(x: 7.6, y: 5.2),
                        controlPoint2: NSPoint(x: 10.4, y: 5.2))
            smile.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
