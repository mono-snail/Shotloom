import AppKit
import Vision

struct ContentBoundary: Identifiable {
    let id = UUID()
    let bounds: CGRect // normalized bottom-left
    let confidence: Float
    let text: Bool
}
enum ContentBoundaryEngine {
    static func detect(_ image: CGImage) async throws -> [ContentBoundary] {
        let worker = Task.detached(priority: .userInitiated) {
            let request = VNDetectRectanglesRequest()
            request.minimumConfidence = 0.85; request.maximumObservations = 80; request.minimumSize = 0.01
            request.minimumAspectRatio = 0.02; request.maximumAspectRatio = 1
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            let lines = try await CaptureEngine.recognizeLines(image)
            var result = request.results?.map { ContentBoundary(bounds: $0.boundingBox, confidence: $0.confidence, text: false) } ?? []
            result += lines.filter { $0.confidence >= 0.8 }.prefix(900).map { .init(bounds: $0.bounds, confidence: $0.confidence, text: true) }
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    static func hit(_ point: CGPoint, candidates: [ContentBoundary]) -> ContentBoundary? {
        candidates.filter { $0.confidence >= 0.85 && $0.bounds.contains(point) }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    static func snap(_ rectangle: CGRect, candidates: [ContentBoundary], tolerance: CGSize) -> CGRect {
        let boxes = candidates.filter { $0.confidence >= 0.85 }.map(\.bounds)
        guard !boxes.isEmpty else { return rectangle }
        func nearest(_ value: CGFloat, targets: [CGFloat], limit: CGFloat) -> CGFloat {
            guard limit.isFinite, limit >= 0 else { return value }
            return targets.filter { abs($0 - value) <= limit }.min { abs($0 - value) < abs($1 - value) } ?? value
        }
        let xs = boxes.flatMap { [$0.minX, $0.maxX] }, ys = boxes.flatMap { [$0.minY, $0.maxY] }
        let x0 = nearest(rectangle.minX, targets: xs, limit: tolerance.width), x1 = nearest(rectangle.maxX, targets: xs, limit: tolerance.width)
        let y0 = nearest(rectangle.minY, targets: ys, limit: tolerance.height), y1 = nearest(rectangle.maxY, targets: ys, limit: tolerance.height)
        guard x1 > x0, y1 > y0 else { return rectangle }
        if x0 == rectangle.minX, x1 == rectangle.maxX, y0 == rectangle.minY, y1 == rectangle.maxY { return rectangle }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    static func dimensions(_ bounds: CGRect, pixels: CGSize, scale: CGFloat) throws -> (pixels: CGSize, logical: CGSize) {
        guard scale.isFinite, (0.5...8).contains(scale), [bounds.width, bounds.height, pixels.width, pixels.height].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, pixels.width > 0, pixels.height > 0 else { throw CaptureError.message(L10n.text("选区或屏幕比例无效。")) }
        let size = CGSize(width: (bounds.width * pixels.width).rounded(), height: (bounds.height * pixels.height).rounded())
        return (size, CGSize(width: size.width / scale, height: size.height / scale))
    }
}
