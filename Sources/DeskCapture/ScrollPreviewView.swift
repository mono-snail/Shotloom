import AppKit
import SwiftUI

/// A scrollable stitched strip. Only the thumbnail strips intersecting the
/// viewport are drawn; export pixels stay in the stitcher's disk-backed tiles.
struct ScrollPreviewView: NSViewRepresentable {
    let preview: ScrollPreview
    let overview: Bool
    @Binding var followsTail: Bool

    func makeNSView(context: Context) -> ScrollPreviewScrollView {
        let scroll = ScrollPreviewScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = ScrollPreviewCanvas()
        return scroll
    }

    func updateNSView(_ scroll: ScrollPreviewScrollView, context: Context) {
        scroll.onUserScroll = { followsTail = $0 }
        scroll.update(preview: preview, overview: overview, followsTail: followsTail)
    }
}

final class ScrollPreviewScrollView: NSScrollView {
    var onUserScroll: ((Bool) -> Void)?
    private var preview = ScrollPreview()
    private var overview = false
    private var followsTail = true
    private var updating = false
    private var contentRevision = 0
    private struct LayoutState: Equatable {
        let viewport: CGSize
        let revision: Int
        let overview: Bool
        let followsTail: Bool
    }
    private var lastLayout: LayoutState?

    func update(preview: ScrollPreview, overview: Bool, followsTail: Bool) {
        let contentChanged = !self.preview.hasSamePresentation(as: preview)
        let displayChanged = self.overview != overview || self.followsTail != followsTail
        guard contentChanged || displayChanged else { return }
        if contentChanged { self.preview = preview; contentRevision += 1 }
        self.overview = overview; self.followsTail = followsTail
        layoutPreview()
    }

    override func layout() { super.layout(); layoutPreview() }

    private func layoutPreview() {
        guard !updating, let canvas = documentView as? ScrollPreviewCanvas else { return }
        updating = true
        defer { updating = false }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let state = LayoutState(viewport: viewport, revision: contentRevision, overview: overview, followsTail: followsTail)
        guard state != lastLayout else { return }
        let previousLayout = lastLayout
        lastLayout = state
        let oldSize = canvas.frame.size
        let oldCount = canvas.preview.tiles.count
        let oldOrigin = contentView.bounds.origin
        let scale = ScrollPreviewGeometry.scale(preview: preview, viewport: viewport, overview: overview)
        canvas.preview = preview; canvas.scale = scale
        let newSize = CGSize(width: max(viewport.width, CGFloat(preview.width) * scale),
                             height: max(viewport.height, CGFloat(preview.height) * scale))
        if oldSize != newSize { canvas.setFrameSize(newSize) }
        if overview || (followsTail && preview.direction == .reverse) { contentView.scroll(to: .zero) }
        else if !followsTail && preview.direction == .reverse && oldCount > 0 && oldCount != preview.tiles.count {
            // New strips prepend to the document. Keep the same source content
            // under a reviewer who has turned off following.
            contentView.scroll(to: preview.axis == .vertical
                ? CGPoint(x: oldOrigin.x, y: max(0, min(newSize.height - viewport.height, oldOrigin.y + newSize.height - oldSize.height)))
                : CGPoint(x: max(0, min(newSize.width - viewport.width, oldOrigin.x + newSize.width - oldSize.width)), y: oldOrigin.y))
        }
        else if followsTail && (oldCount != preview.tiles.count || oldSize != newSize) {
            contentView.scroll(to: preview.axis == .vertical
                ? CGPoint(x: 0, y: max(0, newSize.height - viewport.height))
                : CGPoint(x: max(0, newSize.width - viewport.width), y: 0))
        } else if followsTail {
            // The follow switch can be re-enabled after inspecting earlier strips.
            contentView.scroll(to: preview.axis == .vertical
                ? CGPoint(x: 0, y: max(0, newSize.height - viewport.height))
                : CGPoint(x: max(0, newSize.width - viewport.width), y: 0))
        }
        reflectScrolledClipView(contentView)
        if previousLayout?.revision != state.revision || previousLayout?.viewport != viewport || previousLayout?.overview != overview {
            canvas.needsDisplay = true
        }
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        guard !updating, !overview, let documentView else { return }
        let end = preview.axis == .vertical
            ? max(0, documentView.frame.height - contentView.bounds.height)
            : max(0, documentView.frame.width - contentView.bounds.width)
        let position = preview.axis == .vertical ? contentView.bounds.minY : contentView.bounds.minX
        let atEnd = preview.direction == .reverse ? position <= 3 : position >= end - 3
        guard followsTail != atEnd else { return }
        followsTail = atEnd
        // Includes dragging the scrollbar. Defer the binding write outside any
        // AppKit layout / SwiftUI representable update currently in progress.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.overview, self.followsTail == atEnd else { return }
            self.onUserScroll?(atEnd)
        }
    }
}

final class ScrollPreviewCanvas: NSView {
    var preview = ScrollPreview()
    var scale: CGFloat = 1
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        StudioNativeColor.canvas.setFill(); dirtyRect.fill()
        let drawWidth = CGFloat(preview.width) * scale
        let drawHeight = CGFloat(preview.height) * scale
        let x = preview.axis == .vertical ? (bounds.width - drawWidth) / 2 : 0
        let yBase = preview.axis == .horizontal ? (bounds.height - drawHeight) / 2 : 0
        let backingScale = window?.backingScaleFactor ?? 2
        var sourceY = 0, sourceX = 0
        for tile in preview.tiles {
            // Shared pixel-aligned boundaries avoid hairline gaps between strips
            // when the overview scales a seam onto a fractional screen pixel.
            let rect: CGRect
            if preview.axis == .vertical {
                let y = (CGFloat(sourceY) * scale * backingScale).rounded() / backingScale
                sourceY += tile.sourceHeight
                let bottom = (CGFloat(sourceY) * scale * backingScale).rounded() / backingScale
                rect = CGRect(x: x, y: y, width: drawWidth, height: bottom - y)
            } else {
                let left = (CGFloat(sourceX) * scale * backingScale).rounded() / backingScale
                sourceX += tile.sourceWidth
                let right = (CGFloat(sourceX) * scale * backingScale).rounded() / backingScale
                rect = CGRect(x: left, y: yBase, width: right - left, height: drawHeight)
            }
            if rect.intersects(dirtyRect) {
                NSImage(cgImage: tile.image, size: .zero).draw(in: rect, from: .zero, operation: .copy,
                                                             fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if preview.tiles.filter({ $0.id > 0 }).count > 1, let added = preview.direction == .reverse ? preview.tiles.first(where: { $0.id > 0 }) : preview.tiles.last(where: { $0.id > 0 }) {
            let leading = preview.tiles.first(where: { $0.id == -1 }).map { preview.axis == .vertical ? $0.sourceHeight : $0.sourceWidth } ?? 0
            let trailing = preview.tiles.first(where: { $0.id == -2 }).map { preview.axis == .vertical ? $0.sourceHeight : $0.sourceWidth } ?? 0
            let seam = CGFloat(preview.direction == .reverse
                ? leading + (preview.axis == .vertical ? added.sourceHeight : added.sourceWidth)
                : (preview.axis == .vertical ? preview.height - added.sourceHeight : preview.width - added.sourceWidth) - trailing) * scale
            NSColor(calibratedRed: 0.55, green: 0.90, blue: 0.96, alpha: 0.85).setFill()
            if preview.axis == .vertical { CGRect(x: x, y: seam, width: drawWidth, height: 1).fill() }
            else { CGRect(x: seam, y: yBase, width: 1, height: drawHeight).fill() }
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { L10n.text("已拼接长图预览，\(preview.width) × \(preview.height) 像素，\(preview.tiles.filter { $0.id > 0 }.count) 段") }
}

enum ScrollPreviewGeometry {
    static func scale(preview: ScrollPreview, viewport: CGSize, overview: Bool) -> CGFloat {
        guard preview.width > 0, preview.height > 0 else { return 1 }
        let widthScale = min(1, viewport.width / CGFloat(preview.width))
        let heightScale = min(1, viewport.height / CGFloat(preview.height))
        return overview ? min(widthScale, heightScale) : (preview.axis == .vertical ? widthScale : heightScale)
    }

    static func panelFrame(selection: CGRect, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let inset = visibleFrame.insetBy(dx: 12, dy: 12)
        let fitted = CGSize(width: min(size.width, inset.width), height: min(size.height, inset.height))
        func clamped(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: min(max(inset.minX, x), inset.maxX - fitted.width),
                   y: min(max(inset.minY, y), inset.maxY - fitted.height), width: fitted.width, height: fitted.height)
        }
        let candidates = [
            clamped(selection.maxX + 12, selection.maxY - fitted.height),
            clamped(selection.minX - fitted.width - 12, selection.maxY - fitted.height),
            clamped(selection.minX, selection.minY - fitted.height - 12),
            clamped(selection.minX, selection.maxY + 12),
            clamped(inset.minX, inset.minY), clamped(inset.maxX - fitted.width, inset.minY),
            clamped(inset.minX, inset.maxY - fitted.height), clamped(inset.maxX - fitted.width, inset.maxY - fitted.height)
        ]
        return candidates.enumerated().min { a, b in
            let aa = a.element.intersection(selection), bb = b.element.intersection(selection)
            let areaA = aa.isNull ? 0 : aa.width * aa.height, areaB = bb.isNull ? 0 : bb.width * bb.height
            return areaA == areaB ? a.offset < b.offset : areaA < areaB
        }!.element
    }
}

private extension ScrollPreview {
    /// Polling status is not new media. Thumbnail identities survive value copies.
    func hasSamePresentation(as other: Self) -> Bool {
        axis == other.axis && direction == other.direction && width == other.width && height == other.height
        && tiles.count == other.tiles.count && zip(tiles, other.tiles).allSatisfy { a, b in
            a.id == b.id && a.sourceWidth == b.sourceWidth && a.sourceHeight == b.sourceHeight && a.image === b.image
        }
    }
}
