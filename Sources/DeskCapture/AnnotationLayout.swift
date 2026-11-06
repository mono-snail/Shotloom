import Foundation

struct AnnotationSnapGuide: Equatable {
    enum Axis: Equatable { case vertical, horizontal }
    let axis: Axis
    let position: CGFloat
}
struct AnnotationSnapResult {
    let delta: CGPoint
    let guides: [AnnotationSnapGuide]

    func guides(afterApplying actual: CGPoint) -> [AnnotationSnapGuide] {
        guides.filter { guide in
            let expected = guide.axis == .vertical ? delta.x : delta.y
            let applied = guide.axis == .vertical ? actual.x : actual.y
            let roundoff = 8 * CGFloat.ulpOfOne * max(1, max(abs(expected), abs(applied)))
            return applied.isFinite && abs(expected - applied) <= roundoff
        }
    }
}

enum AnnotationArrangement: String, CaseIterable, Identifiable {
    case left, centerX, right, bottom, centerY, top, horizontalGaps, verticalGaps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: L10n.text("左对齐"); case .centerX: L10n.text("水平居中"); case .right: L10n.text("右对齐")
        case .bottom: L10n.text("底部对齐"); case .centerY: L10n.text("垂直居中"); case .top: L10n.text("顶部对齐")
        case .horizontalGaps: L10n.text("水平均匀间距"); case .verticalGaps: L10n.text("垂直均匀间距")
        }
    }
}
enum AnnotationLayout {
    static func translations(_ bounds: [CGRect], operation: AnnotationArrangement) -> [CGPoint] {
        guard bounds.count >= 2 else { return bounds.map { _ in .zero } }
        let union = bounds.reduce(CGRect.null) { $0.union($1) }
        if operation == .horizontalGaps || operation == .verticalGaps {
            guard bounds.count >= 3 else { return bounds.map { _ in .zero } }
            let horizontal = operation == .horizontalGaps
            let order = bounds.indices.sorted {
                let a = horizontal ? bounds[$0].minX : bounds[$0].minY
                let b = horizontal ? bounds[$1].minX : bounds[$1].minY
                return a == b ? $0 < $1 : a < b
            }
            let extent = horizontal ? union.width : union.height
            let occupied = bounds.reduce(CGFloat.zero) { $0 + (horizontal ? $1.width : $1.height) }
            let gap = (extent - occupied) / CGFloat(bounds.count - 1)
            // Negative gaps deliberately retain equal overlaps instead of silently
            // changing to equal centers or moving the outside objects.
            var cursor = horizontal ? union.minX : union.minY
            var result = bounds.map { _ in CGPoint.zero }
            for index in order {
                let origin = horizontal ? bounds[index].minX : bounds[index].minY
                result[index] = horizontal ? CGPoint(x: cursor - origin, y: 0) : CGPoint(x: 0, y: cursor - origin)
                cursor += (horizontal ? bounds[index].width : bounds[index].height) + gap
            }
            return result
        }
        return bounds.map { box in
            switch operation {
            case .left: CGPoint(x: union.minX - box.minX, y: 0)
            case .centerX: CGPoint(x: union.midX - box.midX, y: 0)
            case .right: CGPoint(x: union.maxX - box.maxX, y: 0)
            case .bottom: CGPoint(x: 0, y: union.minY - box.minY)
            case .centerY: CGPoint(x: 0, y: union.midY - box.midY)
            case .top: CGPoint(x: 0, y: union.maxY - box.maxY)
            default: .zero
            }
        }
    }
    static func snapped(_ delta: CGPoint, group: CGRect, targets: [CGRect], tolerance: CGSize) -> CGPoint {
        snap(delta, group: group, targets: targets, tolerance: tolerance).delta
    }
    static func snap(_ delta: CGPoint, group: CGRect, targets: [CGRect], tolerance: CGSize) -> AnnotationSnapResult {
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite && [rect.minX, rect.maxX, rect.minY, rect.maxY].allSatisfy(\.isFinite)
        }
        guard delta.x.isFinite, delta.y.isFinite, valid(group) else { return .init(delta: delta, guides: []) }
        func correction(_ anchors: [CGFloat], _ targets: [CGFloat], tolerance: CGFloat) -> (delta: CGFloat, position: CGFloat)? {
            guard tolerance.isFinite, tolerance >= 0 else { return nil }
            var best: (delta: CGFloat, position: CGFloat)?
            for anchor in anchors {
                for target in targets {
                    let delta = target - anchor
                    let scale: CGFloat = max(1, max(abs(delta), abs(tolerance)))
                    let roundoff = CGFloat(8) * CGFloat.ulpOfOne * scale
                    if abs(delta) <= tolerance + roundoff, best == nil || abs(delta) < abs(best!.delta) {
                        best = (delta, target)
                    }
                }
            }
            return best
        }
        let moved = group.offsetBy(dx: delta.x, dy: delta.y)
        guard valid(moved) else { return .init(delta: delta, guides: []) }
        let targets = targets.filter(valid)
        let x = correction([moved.minX, moved.midX, moved.maxX], [0, 0.5, 1] + targets.flatMap { [$0.minX, $0.midX, $0.maxX] }, tolerance: tolerance.width)
        let y = correction([moved.minY, moved.midY, moved.maxY], [0, 0.5, 1] + targets.flatMap { [$0.minY, $0.midY, $0.maxY] }, tolerance: tolerance.height)
        var guides: [AnnotationSnapGuide] = []
        if let x { guides.append(.init(axis: .vertical, position: x.position)) }
        if let y { guides.append(.init(axis: .horizontal, position: y.position)) }
        return .init(delta: CGPoint(x: delta.x + (x?.delta ?? 0), y: delta.y + (y?.delta ?? 0)), guides: guides)
    }
}
