import AppKit
import CoreText
import Combine
import SwiftUI

struct SpeakerNotesOptions: Codable, Equatable {
    var fontSize = 28.0
    var speed = 24.0 // logical points per second
    var opacity = 0.85
    var width = 600.0
    var height = 240.0
    var bottom = false
    func validate() throws {
        guard [fontSize, speed, opacity, width, height].allSatisfy(\.isFinite), (16...64).contains(fontSize),
              (4...100).contains(speed), (0.3...1).contains(opacity), (320...1000).contains(width), (140...500).contains(height) else {
            throw CaptureError.message(L10n.text("提词器字号、滚速、透明度或尺寸无效。"))
        }
    }
}
struct SpeakerNotesScroll {
    private(set) var offset = 0.0
    private var last: Double?
    mutating func reset() { offset = 0; last = nil }
    mutating func suspendClock() { last = nil }
    mutating func tick(at uptime: Double, active: Bool, speed: Double, maximum: Double) {
        guard uptime.isFinite, speed.isFinite, maximum.isFinite, speed >= 0, maximum >= 0 else { return }
        defer { last = uptime; offset = min(maximum, max(0, offset)) }
        guard let last, active else { return }
        // Avoid a large visible jump after a stalled event loop or sleep.
        offset += min(0.25, max(0, uptime - last)) * speed
    }
    mutating func resize(from old: Double, to new: Double) {
        offset = old > 0 ? min(max(0, new), max(0, offset / old * new)) : 0
        last = nil
    }
}
struct SpeakerNotesLayout: @unchecked Sendable {
    let lines: [CTLine]
    let lineHeight: CGFloat
    let fontSize: CGFloat
    let width: CGFloat
    var height: CGFloat { CGFloat(lines.count) * lineHeight + 48 }
    static func create(_ text: String, options: SpeakerNotesOptions) throws -> Self {
        try options.validate(); try Task.checkCancellation()
        guard text.utf8.prefix(65_537).count <= 65_536 else { throw CaptureError.message(L10n.text("讲稿最多64KB，原文保留，请拆分稿件。")) }
        let font = CTFontCreateUIFontForLanguage(.system, options.fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, options.fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var lines: [CTLine] = [], offset = 0
        while offset < attributed.length {
            try Task.checkCancellation()
            guard lines.count < 10_000 else { throw CaptureError.message(L10n.text("讲稿行数过多，请拆分稿件。")) }
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, options.width - 48))
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: min(count, attributed.length - offset))))
            offset += count
        }
        return .init(lines: lines, lineHeight: options.fontSize * 1.45, fontSize: options.fontSize, width: options.width)
    }
}
private final class SpeakerNotesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class SpeakerNotesCanvas: NSView {
    var layout: SpeakerNotesLayout?
    var offset = 0.0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor); context.fill(bounds)
        guard let layout else { return }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let start = max(0, Int((offset - 24) / Double(layout.lineHeight)))
        let end = min(layout.lines.count, start + Int(ceil(bounds.height / layout.lineHeight)) + 3)
        guard end > start else { return }
        for index in start..<end {
            context.textPosition = CGPoint(x: 24, y: 24 + layout.fontSize + CGFloat(index) * layout.lineHeight - offset)
            CTLineDraw(layout.lines[index], context)
        }
    }
}

@MainActor final class SpeakerNotesController: ObservableObject {
    @Published var text = "" { didSet { scheduleLayout() } }
    @Published var options = SpeakerNotesOptions() { didSet {
        persist()
        if options.fontSize != oldValue.fontSize || options.width != oldValue.width { scheduleLayout() }
        else {
            scroll.resize(from: max(0, Double(layout?.height ?? 0) - oldValue.height), to: max(0, Double(layout?.height ?? 0) - options.height))
            offset = scroll.offset; refresh()
        }
    } }
    @Published var enabled = false { didSet { preferences.set(enabled, forKey: "speakerNotesEnabled"); refresh() } }
    @Published var scrolling = true
    @Published private(set) var error: String?
    @Published private(set) var offset = 0.0
    private let preferences: UserDefaults
    private var state = RecordingState.idle
    private var safeToShow = false
    private var screen: NSScreen?
    private var panel: SpeakerNotesPanel?
    private let canvas = SpeakerNotesCanvas()
    private var editor: NSWindow?
    private var layout: SpeakerNotesLayout?
    private var scroll = SpeakerNotesScroll()
    private var timer: Timer?
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    var windowID: UInt32? { guard let number = panel?.windowNumber, number > 0 else { return nil }; return UInt32(number) }
    init(preferences: UserDefaults = AppPreferences.standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: "speakerNotesOptions"), data.count <= 4096,
           let stored = try? JSONDecoder().decode(SpeakerNotesOptions.self, from: data), (try? stored.validate()) != nil { options = stored }
        enabled = preferences.bool(forKey: "speakerNotesEnabled")
    }
    private func persist() {
        guard (try? options.validate()) != nil, let data = try? JSONEncoder().encode(options) else { return }
        preferences.set(data, forKey: "speakerNotesOptions")
    }
    func configureCapture(excluded: Bool, screen: NSScreen) { safeToShow = excluded; self.screen = screen; error = nil; scheduleLayout() }
    func recordingStateChanged(_ state: RecordingState) {
        scroll.suspendClock()
        self.state = state
        if state == .idle {
            safeToShow = false; scroll.reset(); offset = 0
            generation = UUID(); preparation?.cancel(); preparation = nil; layout = nil; canvas.layout = nil
        }
        refresh()
    }
    func rewind() { scroll.reset(); offset = 0; canvas.offset = 0; canvas.needsDisplay = true }
    private func scheduleLayout() {
        preparation?.cancel(); generation = UUID(); let request = generation, text = text
        var options = options
        if let screen, screen.visibleFrame.width >= 352 { options.width = min(options.width, screen.visibleFrame.width - 32) }
        layout = nil; hide(); error = nil
        preparation = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let worker = Task.detached { try SpeakerNotesLayout.create(text, options: options) }
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, generation == request else { return }
                preparation = nil; layout = prepared; canvas.layout = prepared; refresh()
            } catch { if generation == request { preparation = nil; if !Task.isCancelled { self.error = error.localizedDescription } } }
        }
    }
    private func refresh() {
        guard enabled, state == .recording || state == .paused else { hide(); return }
        guard safeToShow else { hide(); error = L10n.text("当前录制过滤器无法确认排除提词窗口，暂未显示讲稿。"); return }
        guard let layout, !layout.lines.isEmpty else { if !text.isEmpty && preparation == nil { scheduleLayout() }; hide(); return }
        guard let screen = screen ?? NSScreen.main else { hide(); return }
        if panel == nil {
            let window = SpeakerNotesPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "DeskCapture Speaker Notes"; window.isReleasedWhenClosed = false
            window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.ignoresMouseEvents = true
            window.sharingType = .none // Defense in depth; the SCContentFilter is authoritative.
            window.contentView = canvas; panel = window
        }
        let visible = screen.visibleFrame
        let width = min(options.width, max(100, visible.width - 32)), height = min(options.height, max(100, visible.height - 32))
        let rect = CGRect(x: visible.midX - width / 2, y: options.bottom ? visible.minY + 24 : visible.maxY - height - 48, width: width, height: height)
        panel?.setFrame(rect, display: true); panel?.alphaValue = options.opacity
        canvas.layout = layout; canvas.offset = offset; canvas.needsDisplay = true
        panel?.orderFrontRegardless()
        if timer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    private func tick() {
        let viewport = canvas.bounds.height > 0 ? Double(canvas.bounds.height) : options.height
        let maximum = max(0, Double(layout?.height ?? 0) - viewport)
        scroll.tick(at: ProcessInfo.processInfo.systemUptime, active: state == .recording && scrolling, speed: options.speed, maximum: maximum)
        offset = scroll.offset; canvas.offset = offset; canvas.needsDisplay = true
    }
    private func hide() { panel?.orderOut(nil); timer?.invalidate(); timer = nil }
    func showEditor() {
        if editor == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("录制提词稿"); window.isReleasedWhenClosed = false; window.isRestorable = false
            window.contentMinSize = StudioMetrics.workspaceMinimum
            window.contentView = NSHostingView(rootView: SpeakerNotesEditor(controller: self)); editor = window
        }
        editor?.center(); NSApp.activate(ignoringOtherApps: true); editor?.makeKeyAndOrderFront(nil)
    }
    func awaitLayoutForDiagnostics() async { await preparation?.value }
    var panelForDiagnostics: NSWindow? { panel }
}
