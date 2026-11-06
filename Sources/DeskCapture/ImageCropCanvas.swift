import SwiftUI
import AppKit

/// Pixel coordinates always refer to the unmodified source, with a top-left origin.
/// Crop and strip selections therefore remain stable while switching previews or undoing.
enum ImageCropGeometry {
    static func bounded(_ rect: CGRect, size: CGSize) -> CGRect? {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return nil }
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let left = max(0, floor(clipped.minX)), top = max(0, floor(clipped.minY))
        return CGRect(x: left, y: top, width: min(size.width, ceil(clipped.maxX)) - left,
                      height: min(size.height, ceil(clipped.maxY)) - top)
    }
    static func translatedStrips(_ strips: [ImageStrip], crop: CGRect) -> [ImageStrip] {
        strips.compactMap { strip in
            let origin = Int(strip.axis == .rows ? crop.minY : crop.minX)
            let limit = Int(strip.axis == .rows ? crop.maxY : crop.maxX)
            let start = max(origin, strip.start), end = min(limit, strip.end)
            guard end > start else { return nil }
            return ImageStrip(axis: strip.axis, start: start - origin, end: end - origin)
        }
    }
}

enum ImageCleanupSelection: String, CaseIterable, Identifiable {
    case crop, strips
    var id: Self { self }
    var title: String { self == .crop ? L10n.text("裁剪") : L10n.text("删段") }
    var symbol: String { self == .crop ? "crop" : "rectangle.split.3x1" }
}

struct ImageCropCanvas: View {
    let image: CGImage
    let sourceSize: CGSize
    let showSource: Bool
    let mode: ImageCleanupSelection
    let axis: ImageStripAxis
    let strips: [ImageStrip]
    @Binding var crop: CGRect?
    let zoom: CGFloat?
    let addStrip: (Int, Int) -> Void
    @State private var draft: CGRect?
    @State private var gestureStart: CGRect?
    @State private var operation: Operation?
    private enum Operation {
        case draw, move, resize(Int, Int), strip
    }

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: image.width, height: image.height)
            let fit = min(max(1, geometry.size.width - 48) / size.width,
                          max(1, geometry.size.height - 48) / size.height, 1)
            let scale = zoom == -1 ? max(1, geometry.size.width - 48) / size.width : (zoom ?? fit)
            let displayed = CGSize(width: size.width * scale, height: size.height * scale)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: NSImage(cgImage: image, size: size))
                        .resizable().interpolation(.high)
                        .frame(width: displayed.width, height: displayed.height)
                    if showSource {
                        overlays(scale: scale, displayed: displayed)
                    }
                }
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .gesture(selectionGesture(scale: scale))
                .padding(24)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }.background(TransparencyGrid())
        }
        .onChange(of: showSource) { _, _ in clearGesture() }
        .onChange(of: mode) { _, _ in clearGesture() }
        .accessibilityLabel(showSource ? L10n.text("原图，拖动框选\(mode.title)范围") : L10n.text("处理结果"))
    }

    @ViewBuilder
    private func overlays(scale: CGFloat, displayed: CGSize) -> some View {
        let selection = mode == .crop ? (draft ?? crop) : crop
        if let selection {
            let r = selection.applying(CGAffineTransform(scaleX: scale, y: scale))
            Path { path in
                path.addRect(CGRect(origin: .zero, size: displayed))
                path.addRect(r)
            }.fill(.black.opacity(0.56), style: FillStyle(eoFill: true))
            Rectangle().strokeBorder(.white, lineWidth: 1)
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            if mode == .crop {
                Path { path in
                    for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                        path.move(to: CGPoint(x: r.minX + r.width * fraction, y: r.minY))
                        path.addLine(to: CGPoint(x: r.minX + r.width * fraction, y: r.maxY))
                        path.move(to: CGPoint(x: r.minX, y: r.minY + r.height * fraction))
                        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * fraction))
                    }
                }.stroke(.white.opacity(0.35), lineWidth: 0.5)
                ForEach(0..<8, id: \.self) { index in
                    let anchor = anchors[index]
                    Circle().fill(.white).overlay(Circle().stroke(Palette.ice, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(x: r.minX + r.width * anchor.x, y: r.minY + r.height * anchor.y)
                }
            }
        }
        ForEach(strips) { strip in
            let r = ImageCleanupView.stripRect(strip, image: sourceSize, fit: displayed)
            Rectangle().fill(.red.opacity(0.32))
                .overlay(Rectangle().strokeBorder(.red.opacity(0.8), lineWidth: 1))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
        }
        if mode == .strips, let draft {
            let r = draft.applying(CGAffineTransform(scaleX: scale, y: scale))
            Rectangle().fill(Palette.ice.opacity(0.35)).frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
    }
    private var anchors: [CGPoint] {
        [.init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 0.5),
         .init(x: 1, y: 1), .init(x: 0.5, y: 1), .init(x: 0, y: 1), .init(x: 0, y: 0.5)]
    }
    private func selectionGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard showSource else { return }
                let start = pixel(value.startLocation, scale: scale)
                let point = pixel(value.location, scale: scale)
                if operation == nil {
                    gestureStart = crop
                    operation = hit(start, scale: scale)
                }
                switch operation {
                case .draw:
                    draft = rectangle(start, point)
                case .move:
                    guard let base = gestureStart else { return }
                    draft = CGRect(x: min(sourceSize.width - base.width, max(0, (base.minX + point.x - start.x).rounded())),
                                   y: min(sourceSize.height - base.height, max(0, (base.minY + point.y - start.y).rounded())),
                                   width: base.width, height: base.height)
                case .resize(let x, let y):
                    guard let base = gestureStart else { return }
                    let left = x == 0 ? min(point.x, base.maxX - 1) : base.minX
                    let right = x == 2 ? max(point.x, base.minX + 1) : base.maxX
                    let top = y == 0 ? min(point.y, base.maxY - 1) : base.minY
                    let bottom = y == 2 ? max(point.y, base.minY + 1) : base.maxY
                    draft = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                case .strip:
                    draft = axis == .rows
                        ? CGRect(x: 0, y: min(start.y, point.y), width: sourceSize.width, height: abs(point.y - start.y))
                        : CGRect(x: min(start.x, point.x), y: 0, width: abs(point.x - start.x), height: sourceSize.height)
                case nil: break
                }
            }
            .onEnded { _ in
                defer { clearGesture() }
                guard let draft, let bounded = ImageCropGeometry.bounded(draft, size: sourceSize) else { return }
                if mode == .crop { crop = bounded }
                else {
                    addStrip(Int(axis == .rows ? bounded.minY : bounded.minX),
                             Int(axis == .rows ? bounded.maxY : bounded.maxX))
                }
            }
    }
    private func pixel(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: min(sourceSize.width, max(0, p.x / scale)), y: min(sourceSize.height, max(0, p.y / scale)))
    }
    private func rectangle(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func hit(_ point: CGPoint, scale: CGFloat) -> Operation {
        guard mode == .crop else { return .strip }
        guard let crop else { return .draw }
        // A fixed screen-space hit area keeps tiny source pixel handles usable at any zoom.
        let tolerance = 10 / scale
        for anchor in anchors {
            let p = CGPoint(x: crop.minX + crop.width * anchor.x, y: crop.minY + crop.height * anchor.y)
            if hypot(point.x - p.x, point.y - p.y) <= tolerance {
                return .resize(Int(anchor.x * 2), Int(anchor.y * 2))
            }
        }
        return crop.contains(point) ? .move : .draw
    }
    private func clearGesture() { draft = nil; gestureStart = nil; operation = nil }
}
