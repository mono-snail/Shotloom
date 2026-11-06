import AppKit

enum EditorZoomGeometry {
    static func scale(image: CGSize, viewport: CGSize, zoom: CGFloat?) -> CGFloat {
        if let zoom { return min(8, max(0.1, zoom)) }
        return max(0.001, min(max(1, viewport.width - 48) / image.width,
                              max(1, viewport.height - 48) / image.height))
    }

    static func canvasSize(image: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: max(viewport.width, image.width * scale + 48),
               height: max(viewport.height, image.height * scale + 48))
    }

    static func origin(center: CGPoint, image: CGSize, canvas: CGSize, viewport: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(x: min(max(0, (canvas.width - image.width * scale) / 2 + center.x * image.width * scale - viewport.width / 2), max(0, canvas.width - viewport.width)),
                y: min(max(0, (canvas.height - image.height * scale) / 2 + center.y * image.height * scale - viewport.height / 2), max(0, canvas.height - viewport.height)))
    }
}

/// Zoom changes only the editing viewport; annotations keep image coordinates.
final class EditorCanvasScrollView: NSScrollView {
    var onZoom: ((CGFloat) -> Void)?
    var onDisplayedZoom: ((CGFloat) -> Void)?
    private var zoom: CGFloat?
    private var displayedZoom: CGFloat = 0
    private var updating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(zoom: CGFloat?) {
        self.zoom = zoom
        layoutCanvas()
        documentView?.needsDisplay = true
    }

    override func layout() { super.layout(); layoutCanvas() }

    override func magnify(with event: NSEvent) {
        let scale = min(8, max(0.1, displayedZoom * (1 + event.magnification)))
        update(zoom: scale)
        onZoom?(scale)
    }

    private func layoutCanvas() {
        guard !updating, let canvas = documentView as? AnnotationCanvas else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        updating = true
        defer { updating = false }
        let image = CGSize(width: canvas.document.original.width, height: canvas.document.original.height)
        let scale = EditorZoomGeometry.scale(image: image, viewport: viewport, zoom: zoom)
        let size = EditorZoomGeometry.canvasSize(image: image, viewport: viewport, scale: scale)
        guard canvas.frame.size != size || canvas.imageDisplayScale != scale else { return }
        let oldScale = canvas.imageDisplayScale ?? scale
        let oldSize = canvas.frame.size
        let center = oldSize == .zero ? CGPoint(x: 0.5, y: 0.5) : CGPoint(
            x: (contentView.bounds.midX - (oldSize.width - image.width * oldScale) / 2) / (image.width * oldScale),
            y: (contentView.bounds.midY - (oldSize.height - image.height * oldScale) / 2) / (image.height * oldScale))
        canvas.document.commitPendingText?()
        canvas.imageDisplayScale = scale
        canvas.setFrameSize(size)
        contentView.scroll(to: EditorZoomGeometry.origin(center: center, image: image, canvas: size, viewport: viewport, scale: scale))
        reflectScrolledClipView(contentView)
        canvas.needsDisplay = true
        window?.invalidateCursorRects(for: canvas)
        if displayedZoom != scale {
            displayedZoom = scale
            // SwiftUI may be updating this view; publish after that update ends.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onDisplayedZoom?(self.displayedZoom)
            }
        }
    }
}
