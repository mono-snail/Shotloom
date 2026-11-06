import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Only explicitly generated TextEdit documents. Accepted frames are checked
/// against accessibility glyph displacement, independently of seam matching.
@MainActor
enum NativeScrollDiagnostic {
    static func run(root: URL) async throws -> [String: Any] {
        guard let folder = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_FIXTURE_DIR"],
              let id = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_CASE"],
              id.hasPrefix("T"), id.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw CaptureError.message("Explicit generated TextEdit case required")
        }
        let input = URL(fileURLWithPath: folder).appendingPathComponent("DeskCapture-Fixture-\(id).rtfd")
        let reverse = (Int(id.dropFirst()) ?? 0) % 2 == 0
        let content = try await CaptureEngine().content()
        let windows = content.windows.filter { $0.isOnScreen && $0.owningApplication?.bundleIdentifier == "com.apple.TextEdit" && ($0.title?.contains("DeskCapture-Fixture-\(id)") ?? false) }
        guard windows.count == 1, let window = windows.first, let owner = window.owningApplication else { throw CaptureError.message("Exactly one owned TextEdit document required") }
        let initial = try await Task.detached { try NativeDocumentProbe.inspect(pid: owner.processID, id: id, source: input) }.value
        guard let text = (initial["elements"] as? [[String: Any]])?.first(where: { $0["textMatchesOwnedInput"] as? Bool == true }),
              let range = text["visibleRange"] as? [Int], range.count == 2, range[1] > 30 else { throw CaptureError.message("Native visible character anchor unavailable") }
        // Offscreen prefix geometry can move during TextKit's deferred layout.
        // Hold one character from the starting visible region instead.
        let characterOffset = reverse ? range[0] + 30 : range[0] + range[1] - 30
        let bounds = try viewport(initial)
        let visible = await Task.detached {
            ScrollContainerDetector.globalTargetPoint(area: bounds, avoiding: [], pid: owner.processID, windowID: window.windowID, windowFrame: window.frame) != nil
        }.value
        guard visible else { throw CaptureError.message("Owned TextEdit document is occluded; no events sent") }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let world = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(world) }) else { throw CaptureError.message("Native fixture viewport crosses screens") }
        let scale = screen.backingScaleFactor
        let model = ScrollCapture()
        defer { Task { await model.cancel() } }
        var sources: [CGImage] = [], anchors: [Double] = []
        model.onDiagnosticAcceptedFrame = { image, number in
            let measured = try await Task.detached { () throws -> [String: Any] in
                let geometry = try NativeDocumentProbe.inspect(pid: owner.processID, id: id, source: input, offsets: [characterOffset])
                let destination = root.appendingPathComponent("native-source-\(number).png")
                try writePNG(image, to: destination)
                try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted]).write(to: root.appendingPathComponent("native-geometry-\(number).json"), options: .atomic)
                return geometry
            }.value
            guard try viewport(measured) == bounds else { throw CaptureError.message("Native viewport changed during capture") }
            sources.append(image); anchors.append(try anchor(measured))
            return number >= 4
        }
        var rendered: CGImage?
        model.onFinish = { image, _ in rendered = image }
        try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), content: content, automatic: false, direction: reverse ? .reverse : .forward)
        guard model.targetWindowGeometry?.id == window.windowID else { throw CaptureError.message("Native target changed; no automatic events sent") }
        guard model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Existing automatic scroll permission unavailable") }
        for _ in 0..<600 where model.frames < 4 {
            if model.paused { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard model.frames == 4, sources.count == 4 else {
            let image = try? await CaptureEngine().visibleRegion(world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), screen: screen, content: content, target: window)
            try Task.checkCancellation()
            try await Task.detached {
                if let image { try writePNG(image, to: root.appendingPathComponent("native-rejected-current.png")) }
                else {
                    try JSONSerialization.data(withJSONObject: ["imageOmitted": true, "reason": "Complete target visibility was not verified"]).write(to: root.appendingPathComponent("native-rejected-image-omitted.json"), options: .atomic)
                }
                let geometry = try NativeDocumentProbe.inspect(pid: owner.processID, id: id, source: input)
                try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted]).write(to: root.appendingPathComponent("native-rejected-geometry.json"), options: .atomic)
            }.value
            throw CaptureError.message("Native capture stopped at \(model.frames): \(model.warning ?? "none")")
        }
        if !model.paused { model.togglePause() }
        let output = root.appendingPathComponent("native-\(id).png")
        await model.finish(output: .file(output))
        guard let rendered, !model.active else { throw CaptureError.message("Native output export failed") }
        let raw = sources, positions = anchors
        let verification = try await Task.detached { try verify(raw, anchors: positions, scale: scale, reverse: reverse, output: rendered, root: root) }.value
        guard verification["differingPixels"] as? Int == 0 else { throw CaptureError.message("Native output differs from glyph-coordinate oracle: \(verification)") }
        return ["fixtureCase": id, "app": owner.bundleIdentifier, "frames": sources.count, "direction": reverse ? "reverse" : "forward", "anchorUTF16Offset": characterOffset, "glyphAnchors": anchors, "viewport": [bounds.minX, bounds.minY, bounds.width, bounds.height], "verification": verification, "output": output.path, "clipboardTouched": false, "userContentUsed": false]
    }
    private nonisolated static func viewport(_ geometry: [String: Any]) throws -> CGRect {
        let elements = geometry["elements"] as? [[String: Any]] ?? []
        func box(_ row: [String: Any]) -> CGRect? {
            guard let b = row["bounds"] as? [Double], b.count == 4 else { return nil }
            return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        }
        guard let area = elements.first(where: { $0["role"] as? String == kAXScrollAreaRole }).flatMap(box), !area.isEmpty else { throw CaptureError.message("Native scroll area missing") }
        var left = area.minX, right = area.maxX, top = area.minY, bottom = area.maxY
        for row in elements {
            guard let b = box(row) else { continue }
            if row["role"] as? String == kAXRulerRole { top = max(top, b.maxY) }
            if row["role"] as? String == kAXScrollBarRole {
                if b.width > b.height { bottom = min(bottom, b.minY) }
                else { right = min(right, b.minX) }
            }
        }
        left = ceil(left); right = floor(right); top = ceil(top); bottom = floor(bottom)
        guard right - left > 100, bottom - top > 100 else { throw CaptureError.message("Native body viewport too small") }
        // Exclude NSScrollView's one-point boundary on both axes. The extreme
        // left column can include the decorated window's translucent corner;
        // it is not document text and must not be a generated pixel fixture.
        return CGRect(x: left, y: top, width: right-left, height: bottom-top).insetBy(dx: 1, dy: 1)
    }
    private nonisolated static func anchor(_ geometry: [String: Any]) throws -> Double {
        guard let rows = geometry["elements"] as? [[String: Any]],
              let text = rows.first(where: { $0["textMatchesOwnedInput"] as? Bool == true }),
              let anchors = text["anchors"] as? [[String: Any]],
              let bounds = anchors.first?["bounds"] as? [Double], bounds.count == 4 else { throw CaptureError.message("Independent visible-glyph anchor unavailable") }
        return bounds[1]
    }
    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CaptureError.message("Native source PNG unavailable") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message("Native source PNG write failed") }
    }
    nonisolated static func verify(_ sources: [CGImage], anchors: [Double], scale: CGFloat, reverse: Bool, output: CGImage, root: URL) throws -> [String: Any] {
        guard let first = sources.first, sources.count == anchors.count else { throw CaptureError.message("Native coordinate transcript missing") }
        let offsets = anchors.map { Int((($0 - anchors[0]) * scale).rounded()) }
        let steps = zip(offsets, offsets.dropFirst()).map { reverse ? $1-$0 : $0-$1 }
        guard steps.allSatisfy({ $0 > 0 && $0 < first.height }), sources.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { throw CaptureError.message("Native glyph displacement is not overlapping and monotonic: \(offsets)") }
        let width = first.width, height = first.height + steps.reduce(0,+)
        guard output.width == width, output.height == height else { throw CaptureError.message("Native dimensions disagree with glyph coordinates: expected \(width)x\(height), actual \(output.width)x\(output.height), anchors \(anchors)") }
        func context() throws -> CGContext {
            guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CaptureError.message("Native RGBA allocation failed") }
            return c
        }
        let expected = try context(), actual = try context()
        var cursor = reverse ? height-first.height : 0
        expected.draw(first, in: CGRect(x: 0, y: height-cursor-first.height, width: width, height: first.height))
        for index in 1..<sources.count {
            let step = steps[index-1]
            guard let strip = sources[index].cropping(to: CGRect(x: 0, y: reverse ? 0 : first.height-step, width: width, height: step)) else { throw CaptureError.message("Native oracle strip missing") }
            if reverse { cursor -= step }
            else { cursor = first.height + steps.prefix(index-1).reduce(0,+) }
            expected.draw(strip, in: CGRect(x: 0, y: height-cursor-step, width: width, height: step))
        }
        if let image = expected.makeImage() { try writePNG(image, to: root.appendingPathComponent("native-independent-expected.png")) }
        actual.draw(output, in: CGRect(x: 0, y: 0, width: width, height: height))
        let a = actual.data!.assumingMemoryBound(to: UInt8.self), b = expected.data!.assumingMemoryBound(to: UInt8.self)
        var differences = 0, maxError = 0
        for pixel in 0..<width*height {
            var changed = false
            for channel in 0..<4 { let e = abs(Int(a[pixel*4+channel])-Int(b[pixel*4+channel])); changed = changed || e > 0; maxError = max(maxError,e) }
            if changed { differences += 1 }
        }
        let result: [String: Any] = ["success": differences == 0, "pixelsCompared": width*height, "differingPixels": differences, "maximumChannelError": maxError, "fullResolutionRGBA": true, "independentOffsets": offsets]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: root.appendingPathComponent("verified-pixels.json"), options: .atomic)
        return result
    }
}
