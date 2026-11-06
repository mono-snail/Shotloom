import AppKit
import Vision

extension AnnotationDocument {
    func liftContent(from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(x: min(a.x, b.x) * CGFloat(original.width), y: (1 - max(a.y, b.y)) * CGFloat(original.height),
            width: abs(a.x - b.x) * CGFloat(original.width), height: abs(a.y - b.y) * CGFloat(original.height)).integral
        guard rect.width > 2, rect.height > 2, let crop = original.cropping(to: rect), let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else { return }
        var erase = makeMark(tool: .erase, points: [a, b]); erase.repairMode = .texture
        var image = makeMark(tool: .image, points: [a, b]); image.overlayImage = crop; image.overlayPNG = data
        addBatch([erase, image]); selectingMark = true
        selectMark(at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), tolerance: .zero)
    }
    static func findElements(_ image: CGImage) async throws -> [CGRect] {
        let task = Task.detached(priority: .userInitiated) {
            let rectangles = VNDetectRectanglesRequest(); rectangles.minimumConfidence = 0.5; rectangles.minimumSize = 0.025
            rectangles.maximumObservations = 60; rectangles.minimumAspectRatio = 0.1; rectangles.maximumAspectRatio = 1
            let text = VNRecognizeTextRequest(); text.recognitionLevel = .fast
            try VNImageRequestHandler(cgImage: image).perform([rectangles, text])
            return (rectangles.results?.map(\.boundingBox) ?? []) + (text.results?.map(\.boundingBox) ?? [])
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

// Share handle geometry between the capture overlay and the editor canvas.
extension AnnotationDocument {
    func imageResizeHandles(in rect: CGRect) -> [CGPoint] {
        guard selectedMarkIDs.count == 1, let mark = selectedMark, mark.tool == .image,
              let a = mark.points.first, let b = mark.points.last else { return [] }
        let box = CGRect(x: rect.minX + min(a.x, b.x) * rect.width,
                         y: rect.minY + min(a.y, b.y) * rect.height,
                         width: abs(b.x - a.x) * rect.width, height: abs(b.y - a.y) * rect.height)
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    func imageResizeHandle(at point: CGPoint, in rect: CGRect) -> Int? {
        imageResizeHandles(in: rect).firstIndex { abs($0.x - point.x) <= 8 && abs($0.y - point.y) <= 8 }
    }

    func drawImageResizeHandles(in rect: CGRect) {
        for point in imageResizeHandles(in: rect) {
            let handle = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); handle.fill()
            NSColor.systemTeal.setStroke(); handle.lineWidth = 1.5; handle.stroke()
        }
    }

    func resizeSelectedImage(from original: [Annotation], corner: Int, by delta: CGPoint) {
        guard selectedMarkIDs.count == 1, (0..<4).contains(corner),
              let index = original.firstIndex(where: { $0.id == selectedMarkID }),
              original[index].tool == .image,
              let a = original[index].points.first, let b = original[index].points.last else { return }
        let width = abs(b.x - a.x), height = abs(b.y - a.y)
        guard width > 0, height > 0 else { return }
        let left = corner == 0 || corner == 3, bottom = corner < 2
        let anchor = CGPoint(x: left ? max(a.x, b.x) : min(a.x, b.x),
                             y: bottom ? max(a.y, b.y) : min(a.y, b.y))
        let dx: CGFloat = left ? -1 : 1, dy: CGFloat = bottom ? -1 : 1
        // Project the pointer onto the original diagonal in pixel space, preserving aspect ratio.
        let pixelWidth = width * CGFloat(self.original.width), pixelHeight = height * CGFloat(self.original.height)
        let scale = 1 + (dx * delta.x * CGFloat(self.original.width) * pixelWidth +
                         dy * delta.y * CGFloat(self.original.height) * pixelHeight) /
                        (pixelWidth * pixelWidth + pixelHeight * pixelHeight)
        let maximum = min((left ? anchor.x : 1 - anchor.x) / width,
                          (bottom ? anchor.y : 1 - anchor.y) / height)
        let minimum = max(1 / pixelWidth, 1 / pixelHeight)
        let factor = min(maximum, max(minimum, scale))
        let end = CGPoint(x: anchor.x + dx * width * factor, y: anchor.y + dy * height * factor)
        var updated = original
        updated[index].points = [CGPoint(x: min(anchor.x, end.x), y: min(anchor.y, end.y)),
                                 CGPoint(x: max(anchor.x, end.x), y: max(anchor.y, end.y))]
        marks = updated
    }
}
