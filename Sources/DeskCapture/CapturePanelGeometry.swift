import AppKit
import SwiftUI

enum CapturePanelGeometry {
    static func clamp(_ frame: CGRect, to visibleFrame: CGRect, margin: CGFloat = 8) -> CGRect {
        let usable = visibleFrame.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(frame.width, max(1, usable.width)),
                          height: min(frame.height, max(1, usable.height)))
        return CGRect(x: min(max(frame.minX, usable.minX), usable.maxX - size.width),
                      y: min(max(frame.minY, usable.minY), usable.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func resized(_ frame: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
        clamp(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
              to: visibleFrame)
    }
}

/// Anchor the size editor to its actual control, including inside a scroll view.
/// Capture panels sit above normal windows, so their popovers must follow that level.
struct CaptureSizePopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.content = content
        context.coordinator.presented = $isPresented
        context.coordinator.schedule(from: view)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.presented = nil
        coordinator.popover?.close()
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var content = AnyView(EmptyView())
        var presented: Binding<Bool>?
        var popover: NSPopover?
        private var scheduled = false

        func schedule(from view: NSView) {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.scheduled = false
                guard let view, let parent = view.window else { return }
                guard self.presented?.wrappedValue == true else { self.popover?.close(); return }
                if let popover = self.popover,
                   let host = popover.contentViewController as? NSHostingController<AnyView> {
                    host.rootView = self.content
                    return
                }
                guard !view.bounds.isEmpty else { return }
                let host = NSHostingController(rootView: self.content)
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = false
                popover.delegate = self
                popover.contentViewController = host
                self.popover = popover
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
                if let popupWindow = host.view.window {
                    popupWindow.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
                    popupWindow.orderFront(nil)
                }
            }
        }
        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if presented?.wrappedValue == true { presented?.wrappedValue = false }
        }
    }
}

/// Explicit AppKit dragging avoids relying on SwiftUI background hit testing.
struct CaptureDragHandle: NSViewRepresentable {
    var move: ((CGSize) -> Void)? = nil
    func makeNSView(context: Context) -> CaptureDragHandleView { CaptureDragHandleView() }
    func updateNSView(_ view: CaptureDragHandleView, context: Context) { view.move = move }
}

final class CaptureDragHandleView: NSView {
    var move: ((CGSize) -> Void)?
    private var previousPoint: CGPoint?
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = L10n.text("拖动移动控制条")
        setAccessibilityLabel(L10n.text("拖动移动控制条"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.55).setFill()
        for x in [bounds.midX - 3, bounds.midX + 3] {
            for y in [bounds.midY - 5, bounds.midY, bounds.midY + 5] {
                NSBezierPath(ovalIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        if move != nil { previousPoint = NSEvent.mouseLocation; return }
        guard let window else { return }
        window.performDrag(with: event)
        if let screen = window.screen {
            window.setFrame(CapturePanelGeometry.clamp(window.frame, to: screen.visibleFrame), display: true)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let previousPoint, let move else { return }
        let point = NSEvent.mouseLocation
        move(CGSize(width: point.x - previousPoint.x, height: point.y - previousPoint.y))
        self.previousPoint = point
    }
    override func mouseUp(with event: NSEvent) { previousPoint = nil }
}
