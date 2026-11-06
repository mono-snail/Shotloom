import CoreGraphics

/// The highlighted rectangle is the exact region that will be captured. Resolve
/// screen furniture and overlapping windows before dismissing the selection UI.
enum ScrollSelectionResolver {
    struct Window {
        let id: CGWindowID
        let title: String
        let frame: CGRect
    }
    struct Result {
        let window: Window
        let rect: CGRect
        let adjusted: Bool
    }
    static func resolve(_ selection: CGRect, windows: [Window]) -> Result? {
        guard [selection.minX, selection.minY, selection.width, selection.height].allSatisfy(\.isFinite),
              selection.width >= 40, selection.height >= 40 else { return nil }
        let center = CGPoint(x: selection.midX, y: selection.midY)
        let candidates = windows.enumerated().filter {
            let area = $0.element.frame.intersection(selection)
            return !area.isNull && area.width >= 40 && area.height >= 40
        }
        let target = candidates.first { $0.element.frame.contains(center) }
            ?? candidates.max {
                let a = $0.element.frame.intersection(selection), b = $1.element.frame.intersection(selection)
                let areaA = a.width * a.height, areaB = b.width * b.height
                return areaA == areaB ? $0.offset > $1.offset : areaA < areaB
            }
        guard let target else { return nil }
        var regions = [selection.intersection(target.element.frame)]
        // Keep a rectangular, unobscured region. Never capture foreign windows
        // simply to make a cross-window selection appear supported.
        for blocker in windows.prefix(target.offset) {
            regions = regions.flatMap { subtract(blocker.frame, from: $0) }
                .filter { $0.width >= 40 && $0.height >= 40 }
            guard !regions.isEmpty, regions.count <= 128 else { return nil }
        }
        guard let region = regions.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return Result(window: target.element, rect: region, adjusted: region != selection)
    }
    private static func subtract(_ obstruction: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(obstruction)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height),
                CGRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height),
                CGRect(x: overlap.minX, y: rect.minY, width: overlap.width, height: overlap.minY - rect.minY),
                CGRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: rect.maxY - overlap.maxY)]
    }
}
