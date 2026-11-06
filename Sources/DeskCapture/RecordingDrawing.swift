import AppKit
import Combine
import CoreImage

struct RecordingDrawingFrame: Codable {
    var time: Double
    var marks: [AnnotationArchive]
}
struct RecordingDrawingTimeline: Codable {
    var version = 1
    var frames: [RecordingDrawingFrame] = []
    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("drawing.json") }
    static func load(_ video: URL) -> Self? {
        guard let data = try? RecordingEditStore.sidecarData(url(for: video), maximumBytes: 20_000_000), data.count < 20_000_000,
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1 else { return nil }
        var timeline = saved
        timeline.frames = Array(saved.frames.filter { $0.time.isFinite && $0.time >= 0 }.sorted { $0.time < $1.time }.prefix(2000))
        return timeline
    }
    func index(at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        var low = 0, high = frames.count
        while low < high { let mid = (low + high) / 2; if frames[mid].time <= time { low = mid + 1 } else { high = mid } }
        return low == 0 ? nil : low - 1
    }
}

// Cache only two rendered states, rather than a full-resolution bitmap per drawing gesture.
final class RecordingDrawingCache: @unchecked Sendable {
    let timeline: RecordingDrawingTimeline
    private let lock = NSLock()
    private var images: [Int: CIImage] = [:]
    private var order: [Int] = []
    init(_ timeline: RecordingDrawingTimeline) { self.timeline = timeline }
    func image(at time: Double, size: CGSize) -> CIImage? {
        guard let index = timeline.index(at: time) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let image = images[index] { return image }
        let marks = timeline.frames[index].marks.prefix(200).map { $0.makeMark() }.filter {
            [.arrow, .rectangle, .ellipse, .pen, .step].contains($0.tool) && $0.points.count <= 10_000
            && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
            && $0.width.isFinite && (1...30).contains($0.width) && $0.fontSize.isFinite && (8...200).contains($0.fontSize)
        }
        guard !marks.isEmpty, size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        AnnotationDocument.draw(Array(marks), in: context, rect: CGRect(origin: .zero, size: size), pixelWidth: size.width)
        guard let cg = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cg); images[index] = image; order.append(index)
        if order.count > 2 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }
}

@MainActor
final class RecordingDrawingController: ObservableObject {
    @Published var toolsVisible = false
    @Published private(set) var isDrawing = false
    @Published private(set) var selectedTool: AnnotationTool = .arrow
    @Published private(set) var selectedColor: AnnotationColor = .coral
    @Published private(set) var lineWidth: CGFloat = 5
    private var previousApplication: NSRunningApplication?
    unowned let recorder: ScreenRecorder
    private var panel: CapturePanel?
    private var canvas: AnnotationCanvas?
    private var document: AnnotationDocument?
    private var subscription: AnyCancellable?
    private(set) var timeline = RecordingDrawingTimeline()
    init(recorder: ScreenRecorder) { self.recorder = recorder }
    func reset() { close(); document = nil; subscription = nil; timeline = RecordingDrawingTimeline() }
    func close() { panel?.close(); panel = nil; canvas = nil; isDrawing = false; toolsVisible = false }
    func followBounds() { panel?.setFrame(recorder.recordingBounds, display: true) }
    func stopDrawing() {
        panel?.ignoresMouseEvents = true; isDrawing = false
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication?.activate(options: []) }
    }
    func setColor(_ color: AnnotationColor) { selectedColor = color; document?.selectColor(color); canvas?.needsDisplay = true }
    func setWidth(_ width: CGFloat) { lineWidth = width; document?.lineWidth = width }
    func undo() { document?.undo(); canvas?.needsDisplay = true }
    func clear() { document?.selectAllMarks(); document?.deleteSelected(); canvas?.needsDisplay = true }
    func draw(_ tool: AnnotationTool) {
        guard recorder.state == .recording else { return }
        let bounds = recorder.recordingBounds
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = front }
        selectedTool = tool; toolsVisible = true; isDrawing = true
        if document == nil {
            let scale = min(2, 3840 / max(bounds.width, bounds.height))
            guard let context = CGContext(data: nil, width: max(2, Int(bounds.width * scale)), height: max(2, Int(bounds.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let blank = context.makeImage() else { return }
            let doc = AnnotationDocument(image: blank); doc.lineWidth = lineWidth; doc.selectColor(selectedColor); document = doc
            subscription = doc.$marks.sink { [weak self] marks in
                guard let self, self.recorder.state == .recording else { return }
                if self.timeline.frames.count < 2000 {
                    self.timeline.frames.append(RecordingDrawingFrame(time: self.recorder.currentRecordingTime, marks: Array(marks.prefix(200)).map(AnnotationArchive.init)))
                }
                DispatchQueue.main.async { self.canvas?.needsDisplay = true }
            }
        }
        guard let doc = document else { return }
        doc.tool = tool; doc.selectingMark = false
        if panel == nil {
            let view = AnnotationCanvas(document: doc); view.transparentOverlay = true; view.onEscape = { [weak self] in self?.stopDrawing() }; view.autoresizingMask = [.width, .height]
            let window = CapturePanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = L10n.text("录屏现场标注"); window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1); window.hasShadow = false; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = view; panel = window; canvas = view
        }
        panel?.ignoresMouseEvents = false; panel?.orderFrontRegardless(); panel?.makeKey(); if let canvas { panel?.makeFirstResponder(canvas) }
    }
}
