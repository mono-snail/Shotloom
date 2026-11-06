import AppKit
import SwiftUI

struct StatusGuideGeometry {
    static let size = NSSize(width: 300, height: 194)
    static func frame(anchor: NSRect, screen: NSRect) -> NSRect {
        let width = min(size.width, screen.width - 24)
        let x = min(max(anchor.midX - width * 0.64, screen.minX + 12), screen.maxX - width - 12)
        return NSRect(x: x, y: max(screen.minY + 12, anchor.minY - size.height), width: width, height: size.height)
    }
}

private final class StatusGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class GuideHostingView: NSHostingView<StatusItemGuideView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class StatusItemGuideController {
    private(set) var panel: NSPanel?
    private var timer: Timer?
    private var deadline = Date.distantPast
    private var attempts = 0
    private var lastTip: CGFloat?
    private var requestedFrame: NSRect?
    private var hostingView: GuideHostingView?
    private weak var item: NSStatusItem?
    private var openMenu: (() -> Void)?
    deinit { timer?.invalidate() }

    func show(relativeTo item: NSStatusItem, openMenu: @escaping () -> Void) {
        // Reopen events can arrive while the launch guide is already showing.
        // Keep its existing view and deadline instead of restarting presentation.
        if self.item === item, timer != nil {
            self.openMenu = openMenu
            return
        }
        dismiss()
        self.item = item; self.openMenu = openMenu
        deadline = Date().addingTimeInterval(10); attempts = 0
        // Status items acquire a screen position after the first window-server layout.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePosition() }
        }
        updatePosition()
    }
    func dismiss() {
        timer?.invalidate(); timer = nil
        panel?.close()
        item = nil; openMenu = nil
    }
    private func updatePosition() {
        guard Date() < deadline else { dismiss(); return }
        guard let item, item.isVisible, let button = item.button, !button.isHidden,
              let window = button.window, let screen = window.screen else {
            attempts += 1
            if attempts >= 15 { dismiss() }
            return
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.intersects(anchor), anchor.width > 0 else { dismiss(); return }
        let frame = StatusGuideGeometry.frame(anchor: anchor, screen: screen.frame)
        let tip = min(max(anchor.midX - frame.minX, 14), frame.width - 14)
        if panel == nil {
            let panel = StatusGuidePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = L10n.text("\(AppIdentity.name) 启动引导")
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.hasShadow = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            self.panel = panel
        }
        guard let panel else { return }
        if hostingView == nil || lastTip != tip {
            lastTip = tip
            let view = StatusItemGuideView(tipX: tip, open: { [weak self] in
                let action = self?.openMenu; self?.dismiss(); action?()
            }, close: { [weak self] in self?.dismiss() })
            if let hostingView {
                hostingView.rootView = view
            } else {
                let hostingView = GuideHostingView(rootView: view)
                self.hostingView = hostingView
                panel.contentView = hostingView
            }
        }
        // Compare requested geometry: AppKit may round the actual window frame.
        // A move must never replace the hosting view or restart its appearance.
        if requestedFrame != frame {
            requestedFrame = frame
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

private struct GuideArrow: Shape {
    var tipX: CGFloat
    func path(in rect: CGRect) -> Path {
        let tip = CGPoint(x: tipX, y: 5)
        let endControl = CGPoint(x: tipX + 48, y: 41)
        // Align the head with the curve's final tangent, rather than vertical.
        let tangentLength = hypot(endControl.x - tip.x, endControl.y - tip.y)
        let back = CGVector(dx: (endControl.x - tip.x) / tangentLength, dy: (endControl.y - tip.y) / tangentLength)
        let base = CGPoint(x: tip.x + back.dx * 22, y: tip.y + back.dy * 22)
        let wing = CGVector(dx: -back.dy * 9, dy: back.dx * 9)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - 35, y: 96))
        p.addCurve(to: tip, control1: CGPoint(x: rect.midX + 85, y: 106), control2: endControl)
        p.move(to: CGPoint(x: base.x + wing.dx, y: base.y + wing.dy))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: base.x - wing.dx, y: base.y - wing.dy))
        return p
    }
}

struct StatusItemGuideView: View {
    var tipX: CGFloat
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        ZStack(alignment: .top) {
            GuideArrow(tipX: tipX).stroke(Palette.paper, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            GuideArrow(tipX: tipX).stroke(Palette.ice, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .shadow(color: Palette.ice.opacity(0.12), radius: 5, y: 2).accessibilityHidden(true)
            HStack(spacing: 11) {
                Button(action: open) {
                    HStack(spacing: 11) {
                        ViewfinderMark(size: 37)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("我在这里")).font(.system(size: 17, weight: .semibold, design: .rounded))
                            Text(L10n.text("点上方图标，开始捕获")).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("打开 \(AppIdentity.name) 主菜单"))
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel(L10n.text("关闭启动引导")).keyboardShortcut(.cancelAction)
            }.foregroundStyle(Palette.white).padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Palette.chrome.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5).padding(.horizontal, 8).padding(.top, 104)
        }
    }
}
