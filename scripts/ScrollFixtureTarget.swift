// Controlled native scroll target; generated pixels only, no user files/settings.
import AppKit
import Darwin

final class FixtureApplication: NSApplication {
    var receivedScrollEvents = 0
    var lastScrollWindow = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            receivedScrollEvents += 1; lastScrollWindow = event.windowNumber
            (delegate as? FixtureDelegate)?.publish()
        }
        super.sendEvent(event)
    }
}

final class TextureView: NSView {
    let image: NSImage
    override var isFlipped: Bool { true }
    init(_ source: CGImage, size: CGSize) {
        image = NSImage(cgImage: source, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
}
final class FixtureScrollView: NSScrollView {
    var onStep: (() -> Void)?
    var delay: TimeInterval = 0
    var transition: TimeInterval = 0
    var pending = 0, maxPending = 0, completed = 0
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let maximum = max(0, documentView.frame.height - contentView.bounds.height)
        let y = max(0, min(maximum, contentView.bounds.minY - event.scrollingDeltaY))
        let original = contentView.bounds.minY
        pending += 1; maxPending = max(maxPending, pending); onStep?()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.transition > 0 {
                self.contentView.scroll(to: CGPoint(x: 0, y: (original + y) / 2)); self.reflectScrolledClipView(self.contentView); self.onStep?()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.transition) { [weak self] in
                guard let self else { return }
                self.contentView.scroll(to: CGPoint(x: 0, y: y)); self.reflectScrolledClipView(self.contentView)
                self.pending -= 1; self.completed += 1; self.onStep?()
            }
        }
    }
}
final class PulseOverlay: NSView {
    var light = false
    var shade: CGFloat?
    var phase: UInt64?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let phase, let context = NSGraphicsContext.current?.cgContext {
            // A 13-step gray cycle aliases screenshot intervals on some hosts.
            // Deterministic per-tick texture has no short repeating frame cycle.
            var seed = phase &* 0x9e3779b97f4a7c15
            context.setShouldAntialias(false)
            for row in 0..<16 { for column in 0..<16 {
                seed = seed &* 6364136223846793005 &+ 1
                context.setFillColor(gray: CGFloat((seed >> 32) & 255) / 255, alpha: 1)
                context.fill(CGRect(x: bounds.minX + CGFloat(column) * bounds.width / 16,
                                    y: bounds.minY + CGFloat(row) * bounds.height / 16,
                                    width: bounds.width / 16 + 1, height: bounds.height / 16 + 1))
            } }
            return
        }
        (shade.map { NSColor(calibratedWhite: $0, alpha: 1) } ?? (light ? NSColor.white : NSColor.black)).setFill(); bounds.fill()
    }
}
final class CaptureBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.12, green: 0.21, blue: 0.31, alpha: 1).setFill(); bounds.fill()
        NSColor(calibratedWhite: 0.65, alpha: 0.25).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 1
        for x in stride(from: CGFloat(0), through: bounds.width, by: 64) { grid.move(to: CGPoint(x: x, y: 0)); grid.line(to: CGPoint(x: x, y: bounds.height)) }
        for y in stride(from: CGFloat(0), through: bounds.height, by: 64) { grid.move(to: CGPoint(x: 0, y: y)); grid.line(to: CGPoint(x: bounds.width, y: y)) }
        grid.stroke()
        ("DeskCapture QA — generated fixture" as NSString).draw(at: CGPoint(x: 50, y: 50), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 24, weight: .medium), .foregroundColor: NSColor.white])
    }
}
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!, scroll: FixtureScrollView!, outer: FixtureScrollView?, timer: Timer?, pulseTimer: Timer?
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let timed = CommandLine.arguments.contains("--timed-steps")
    let nested = CommandLine.arguments.contains("--nested")
    let fixed = CommandLine.arguments.contains("--fixed-bars")
    var motionOverlay: PulseOverlay?
    var motionTick = 0
    var motionControl: URL { output.appendingPathExtension("motion") }
    var capturedView: NSView?
    var backdrops: [NSWindow] = []
    var ownerTimer: Timer?
    var coverTimer: Timer?, partialCover: NSWindow?
    let safePosition = CommandLine.arguments.contains("--safe-position")
    var coverControl: URL { output.appendingPathExtension("cover") }
    let width: CGFloat = 400, pageHeight: CGFloat = 2500, viewportHeight: CGFloat = 600
    let initialY = CGFloat(Double(CommandLine.arguments.first(where: { $0.hasPrefix("--initial-y=") })?.split(separator: "=").last ?? "1600") ?? 1600)
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        let scale = screen.backingScaleFactor
        if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--owner-pid=") }),
           let owner = Int32(value.dropFirst(12)), owner > 0, owner != getpid() {
            ownerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                if kill(owner, 0) != 0 && errno == ESRCH { Task { @MainActor in NSApp.terminate(nil) } }
            }
        }
        if CommandLine.arguments.contains("--capture-backdrop") {
            for display in NSScreen.screens {
                let background = NSWindow(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                background.title = "DeskCapture generated capture background"; background.isReleasedWhenClosed = false
                background.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                background.contentView = CaptureBackdropView(frame: CGRect(origin: .zero, size: display.frame.size))
                background.orderFront(nil); backdrops.append(background)
            }
            if CommandLine.arguments.contains("--backdrop-only") {
                NSApp.activate(ignoringOtherApps:true)
                let metadata:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"generatedBackdropOnly":true]
                for background in backdrops { background.displayIfNeeded() }
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [self] in
                    if let data=try? JSONSerialization.data(withJSONObject:metadata) { try? data.write(to:output,options:.atomic) }
                }
                return
            }
        }
        Task { [self] in
            let image = await Task.detached { Self.texture(width: Int(400 * scale), height: Int(2500 * scale)) }.value
            window = NSWindow(contentRect: CGRect(x: safePosition ? 40 : 300, y: 150, width: width, height: viewportHeight),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "DeskCapture 生成长图测试窗口"; window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            scroll = FixtureScrollView(frame: CGRect(x: 0, y: 0, width: width, height: viewportHeight))
            scroll.delay = Double(CommandLine.arguments.first(where: { $0.hasPrefix("--delay-ms=") })?.split(separator: "=").last ?? "0")! / 1000
            scroll.transition = Double(CommandLine.arguments.first(where: { $0.hasPrefix("--transition-ms=") })?.split(separator: "=").last ?? "0")! / 1000
            scroll.borderType = .noBorder; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
            scroll.documentView = TextureView(image, size: CGSize(width: width, height: pageHeight))
            scroll.onStep = { [weak self] in self?.publish() }
            let capture: NSView
            if fixed {
                let container = NSView(frame: scroll.frame)
                scroll.frame = CGRect(x: 0, y: 28, width: width, height: viewportHeight - 64)
                container.addSubview(scroll)
                let header = await Task.detached { Self.texture(width: Int(400 * scale), height: Int(36 * scale), seed: 777) }.value
                let footer = await Task.detached { Self.texture(width: Int(400 * scale), height: Int(28 * scale), seed: 778) }.value
                let head = TextureView(header, size: CGSize(width: width, height: 36)); head.frame.origin.y = 564
                let tail = TextureView(footer, size: CGSize(width: width, height: 28))
                container.addSubview(head); container.addSubview(tail); capture = container
            } else { capture = scroll }
            capturedView = capture
            if CommandLine.arguments.contains("--animate-corner") {
                let overlay = PulseOverlay(frame: CGRect(x: 0, y: scroll.bounds.height - 40, width: 40, height: 40))
                scroll.addSubview(overlay)
                pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.23, repeats: true) { _ in
                    overlay.light.toggle(); overlay.needsDisplay = true
                }
            }
            if nested {
                let wrapper = FixtureScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
                wrapper.borderType = .noBorder
                let document = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 1800))
                capture.frame = CGRect(x: safePosition ? 0 : 200, y: 1000, width: width, height: viewportHeight)
                document.addSubview(capture); wrapper.documentView = document
                wrapper.onStep = { [weak self] in self?.publish() }
                outer = wrapper; window.setContentSize(CGSize(width: 600, height: 800)); window.contentView = wrapper
                wrapper.contentView.scroll(to: CGPoint(x: 0, y: 1000)); wrapper.reflectScrolledClipView(wrapper.contentView)
            } else { window.contentView = capture }
            if safePosition, let content=window.contentView {
                // Keep the unchanged 400x600 capture area inside opaque content,
                // rather than including the system's rounded window corners.
                let container=NSView(frame:CGRect(origin:.zero,size:CGSize(width:content.frame.width+52,height:content.frame.height+52)))
                content.removeFromSuperview();content.frame.origin=CGPoint(x:26,y:26)
                container.addSubview(content);window.setContentSize(container.frame.size);window.contentView=container
            }
            window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: initialY)); scroll.reflectScrolledClipView(scroll.contentView)
            window.displayIfNeeded()
            // Publish readiness after WindowServer has committed the initial
            // decorated-window geometry, not during its opening transition.
            try? await Task.sleep(for: .milliseconds(500))
            window.displayIfNeeded(); publish()
            if CommandLine.arguments.contains("--visibility-control") {
                coverTimer = Timer.scheduledTimer(withTimeInterval: 0.1,repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCover() }
                }
            }
            if CommandLine.arguments.contains("--motion-control") {
                pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.073, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMotion() }
                }
            }
            if timed {
                timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, self.scroll.contentView.bounds.minY - 113)))
                        self.scroll.reflectScrolledClipView(self.scroll.contentView); self.publish()
                    }
                }
            }
        }
    }
    func updateMotion() {
        if FileManager.default.fileExists(atPath: motionControl.path) {
            if motionOverlay == nil {
                let overlay = PulseOverlay(frame: scroll.bounds.insetBy(dx: 40, dy: 60))
                scroll.addSubview(overlay); motionOverlay = overlay
                if let data = try? Data(contentsOf: motionControl),
                   let y = Double(String(decoding: data, as: UTF8.self)) {
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            motionTick += 1
            motionOverlay?.phase = UInt64(motionTick)
            motionOverlay?.needsDisplay = true
        } else if let overlay = motionOverlay {
            overlay.removeFromSuperview(); motionOverlay = nil
        }
        publish()
    }
    func updateCover() {
        let requested=FileManager.default.fileExists(atPath:coverControl.path)
        if requested,partialCover==nil,let capturedView {
            let area=window.convertToScreen(capturedView.convert(capturedView.bounds,to:nil))
            let cover=NSWindow(contentRect:CGRect(x:area.maxX-50,y:area.minY+12,width:40,height:area.height-24),
                               styleMask:[.borderless],backing:.buffered,defer:false)
            cover.title="DeskCapture generated partial cover";cover.isReleasedWhenClosed=false
            cover.backgroundColor = .systemPurple;cover.isOpaque=true;cover.level = .floating
            cover.orderFrontRegardless();partialCover=cover
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.publish() }
        } else if !requested,let cover=partialCover {
            cover.close();partialCover=nil;publish()
        }
    }
    func publish() {
        guard let window, let scroll, let screen = window.screen else { return }
        let rect = window.convertToScreen((capturedView ?? scroll).convert((capturedView ?? scroll).bounds, to: nil))
        let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                   "rect": [rect.minX, rect.minY, rect.width, rect.height],
                                   "scale": screen.backingScaleFactor, "initialY": initialY,
                                   "currentY": scroll.contentView.bounds.minY, "viewportHeight": scroll.contentView.bounds.height,
                                   "pageWidth": width, "pageHeight": pageHeight, "timed": timed]
        var telemetry = value
        telemetry["motionActive"] = motionOverlay != nil
        telemetry["motionTick"] = motionTick
        telemetry["nested"] = nested
        telemetry["partialCover"] = partialCover != nil
        telemetry["safePosition"] = safePosition
        telemetry["fixedBars"] = fixed
        telemetry["outerY"] = outer?.contentView.bounds.minY ?? 0
        telemetry["pendingScrolls"] = scroll.pending
        telemetry["maxPendingScrolls"] = scroll.maxPending
        telemetry["completedScrolls"] = scroll.completed
        telemetry["delayMS"] = scroll.delay * 1000
        telemetry["transitionMS"] = scroll.transition * 1000
        if let app = NSApp as? FixtureApplication {
            telemetry["receivedScrollEvents"] = app.receivedScrollEvents
            telemetry["lastScrollWindow"] = app.lastScrollWindow
        }
        if let data = try? JSONSerialization.data(withJSONObject: telemetry, options: [.sortedKeys]) { try? data.write(to: output, options: .atomic) }
    }
    nonisolated static func texture(width: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        var state = seed, pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1
            let value = UInt8((state >> 32) & 255)
            pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
MainActor.assumeIsolated {
    let application = FixtureApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = FixtureDelegate()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
}
