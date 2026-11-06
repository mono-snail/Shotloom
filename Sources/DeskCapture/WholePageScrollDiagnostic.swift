import AppKit
import ApplicationServices

/// Explicit diagnostic: one production session must reach the opposite end of
/// an owned generated document. No frame-count stop or user documents.
@MainActor
enum WholePageScrollDiagnostic {
    static func run(root: URL, reverse: Bool) async throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw CaptureError.message("Existing automatic-scroll permission required") }
        let name = reverse ? "reverse" : "forward"
        let metadata = root.appendingPathComponent("whole-page-\(name)-target.json")
        let fixture = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ScrollFixtureTarget.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        // The fixed bars leave a 536-point body: 2500 - 536 = 1964.
        configuration.arguments = [metadata.path, "--nested", "--fixed-bars", "--safe-position",
            "--initial-y=\(reverse ? 1964 : 0)", reverse ? "--delay-ms=1800" : "--delay-ms=900"]
        if !reverse { configuration.arguments.append("--transition-ms=1200") }
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { configuration.environment = ["CFFIXED_USER_HOME": home] }
        let app = try await NSWorkspace.shared.openApplication(at: fixture, configuration: configuration)
        defer { app.terminate() }
        func state() throws -> [String: Any] {
            guard let result = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
                  result["pid"] as? Int32 == app.processIdentifier else { throw CaptureError.message("Owned whole-page target identity changed") }
            return result
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: metadata.path) { try await Task.sleep(for: .milliseconds(50)) }
        let initial = try state()
        guard let box = initial["rect"] as? [Double], box.count == 4,
              let scale = initial["scale"] as? Double,
              let pageHeight = initial["pageHeight"] as? Double,
              let bodyHeight = initial["viewportHeight"] as? Double,
              let initialY = initial["currentY"] as? Double,
              abs(initialY - (reverse ? pageHeight - bodyHeight : 0)) < 0.01 else { throw CaptureError.message("Capture must start at the real document boundary") }
        let world = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(world) }) else { throw CaptureError.message("Owned viewport outside screen") }
        let content = try await CaptureEngine().content()
        guard let target = content.windows.first(where: { $0.isOnScreen && $0.owningApplication?.processID == app.processIdentifier }) else { throw CaptureError.message("Owned fixture not on screen") }
        let model = ScrollCapture()
        defer { Task { await model.cancel() } }
        model.onDiagnosticAcceptedFrame = { image, number in
            let geometry = try state()
            try await Task.detached(priority: .utility) {
                try NativeScrollDiagnostic.writePNG(image, to: root.appendingPathComponent("whole-page-\(name)-source-\(number).png"))
                try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted]).write(to: root.appendingPathComponent("whole-page-\(name)-geometry-\(number).json"), options: .atomic)
            }.value
            return false
        }
        try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), content: content,
                              automatic: false, direction: reverse ? .reverse : .forward)
        guard model.targetWindowGeometry?.id == target.windowID,
              model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Whole-page target or permission unavailable") }
        let expectedEdges = ScrollFixedEdges(leading: Int(36 * scale), trailing: Int(28 * scale))
        let deadline = ProcessInfo.processInfo.systemUptime + 150
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let edges = model.suggestedFixedEdges {
                guard edges == expectedEdges else { throw CaptureError.message("Whole-page fixed-edge suggestion differs") }
                await model.configureFixedEdges(edges)
                guard model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Whole-page resume failed") }
            } else if model.paused { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let final = try state()
        guard let currentY = final["currentY"] as? Double,
              abs(currentY - (reverse ? 0 : pageHeight - bodyHeight)) < 0.01,
              final["pendingScrolls"] as? Int == 0,
              final["maxPendingScrolls"] as? Int == 1,
              initial["outerY"] as? Double == final["outerY"] as? Double,
              model.paused, model.fixedEdges == expectedEdges else {
            throw CaptureError.message("Whole document not complete: frames=\(model.frames), position=\(final["currentY"] ?? "missing"), fixedEdges=\(model.fixedEdges), paused=\(model.paused), pending=\(final["pendingScrolls"] ?? "missing"), maxPending=\(final["maxPendingScrolls"] ?? "missing"), warning=\(model.warning ?? "none")")
        }
        let width = Int((box[2] * scale).rounded()), height = Int(((pageHeight + 64) * scale).rounded())
        guard model.preview.width == width, model.preview.height == height else { throw CaptureError.message("Whole-page output dimensions omit or duplicate content") }
        let frames = model.frames, warning = model.warning ?? ""
        let destination = root.appendingPathComponent("whole-page-\(name).png")
        await model.finish(output: .file(destination))
        guard !model.active else { throw CaptureError.message(model.warning ?? "Whole-page export failed") }
        let verification = try await Task.detached(priority: .userInitiated) { () throws -> [String: Int] in
            let actual = try CaptureImageRead.load(destination)
            guard actual.width == width, actual.height == height else { throw CaptureError.message("Whole-page PNG dimensions changed") }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            func context() throws -> CGContext {
                guard let value = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CaptureError.message("Whole-page oracle allocation failed") }
                return value
            }
            let expected = try context(), decoded = try context()
            let leading = Int(36 * scale), trailing = Int(28 * scale), body = Int((pageHeight * scale).rounded())
            expected.draw(WorkflowCorpus.texture(width: width, height: leading, seed: 777), in: CGRect(x: 0, y: height - leading, width: width, height: leading))
            expected.draw(WorkflowCorpus.texture(width: width, height: body, seed: 42), in: CGRect(x: 0, y: trailing, width: width, height: body))
            expected.draw(WorkflowCorpus.texture(width: width, height: trailing, seed: 778), in: CGRect(x: 0, y: 0, width: width, height: trailing))
            decoded.draw(actual, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let a = expected.data?.assumingMemoryBound(to: UInt8.self),
                  let b = decoded.data?.assumingMemoryBound(to: UInt8.self) else { throw CaptureError.message("Whole-page pixel buffers unavailable") }
            var maximum = 0
            for pixel in 0..<(width * height) {
                let index = pixel * 4
                guard a[index + 3] == b[index + 3] else { throw CaptureError.message("Whole-page alpha changed") }
                for channel in 0..<3 { maximum = max(maximum, abs(Int(a[index + channel]) - Int(b[index + channel]))) }
            }
            // WindowServer quantizes the generated sRGB raster on this display.
            // This checks original content/order; the separate PNG-row oracle
            // requires zero RGBA difference against the accepted screen frames.
            guard maximum <= 2 else { throw CaptureError.message("Whole-page content differs from original: maximum RGB error \(maximum)") }
            return ["pixelsCompared": width * height, "originalMaximumRGBError": maximum, "originalMaximumRGBErrorAllowed": 2]
        }.value
        return ["direction": name, "frames": frames, "pixelsCompared": verification["pixelsCompared"]!,
                "originalMaximumRGBError": verification["originalMaximumRGBError"]!, "originalMaximumRGBErrorAllowed": 2,
                "scale": scale, "leadingPixels": Int(36 * scale), "trailingPixels": Int(28 * scale),
                "startedAtBoundary": true, "reachedOppositeBoundary": true, "fixedEdgesOnlyOnce": true,
                "outerContainerUnchanged": true, "maxPendingScrolls": 1, "completionWarning": warning,
                "output": destination.path, "userContentUsed": false, "clipboardTouched": false]
    }
}
