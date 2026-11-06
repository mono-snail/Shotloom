import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor
enum PreviewScrollDiagnostic {
    static func run(root: URL) async throws -> [String: Any] {
        guard let folder = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_FIXTURE_DIR"],
              let id = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_CASE"], id.hasPrefix("P"),
              id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw CaptureError.message("Explicit generated PDF case required") }
        let source = URL(fileURLWithPath: folder).appendingPathComponent("DeskCapture-Fixture-\(id).pdf")
        let reverse = (Int(id.dropFirst()) ?? 0) % 2 == 0
        let content = try await CaptureEngine().content()
        let windows = content.windows.filter { $0.isOnScreen && $0.owningApplication?.bundleIdentifier == "com.apple.Preview" && ($0.title?.contains("DeskCapture-Fixture-\(id).pdf") ?? false) }
        guard windows.count == 1, let window = windows.first, let owner = window.owningApplication else { throw CaptureError.message("Exactly one owned Preview PDF required") }
        let initial = try await Task.detached { try PreviewDocumentProbe.inspect(pid: owner.processID, id: id, source: source) }.value
        let initialPages = try pages(initial), bounds = try viewport(initial)
        let visible = await Task.detached {
            ScrollContainerDetector.globalTargetPoint(area: bounds, avoiding: [], pid: owner.processID, windowID: window.windowID, windowFrame: window.frame) != nil
        }.value
        guard visible else { throw CaptureError.message("Owned PDF is occluded; no automatic events sent") }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let world = CGRect(x: bounds.minX, y: top-bounds.maxY, width: bounds.width, height: bounds.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(world) }) else { throw CaptureError.message("PDF viewport crosses screens") }
        let scale = screen.backingScaleFactor, frameLimit = 10
        let model = ScrollCapture(); defer { Task { await model.cancel() } }
        var images: [CGImage] = [], positions: [Double] = []
        model.onDiagnosticAcceptedFrame = { image, number in
            let geometry = try await Task.detached { () throws -> [String: Any] in
                let result = try PreviewDocumentProbe.inspect(pid: owner.processID, id: id, source: source)
                try NativeScrollDiagnostic.writePNG(image, to: root.appendingPathComponent("native-source-\(number).png"))
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: root.appendingPathComponent("native-geometry-\(number).json"), options: .atomic)
                return result
            }.value
            let currentPages = try pages(geometry)
            guard try viewport(geometry) == bounds else { throw CaptureError.message("PDF viewport changed") }
            let shift = currentPages[0].minY-initialPages[0].minY
            guard zip(currentPages, initialPages).allSatisfy({ current, original in
                abs(current.width-original.width) < 0.001 && abs(current.height-original.height) < 0.001 &&
                abs(current.minX-original.minX) < 0.001 && abs(current.minY-original.minY-shift) < 0.001
            }) else { throw CaptureError.message("PDF page geometry did not move uniformly") }
            images.append(image); positions.append(currentPages[0].minY)
            return number >= frameLimit
        }
        var rendered: CGImage?
        model.onFinish = { image, _ in rendered = image }
        try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), content: content, automatic: false, direction: reverse ? .reverse : .forward)
        guard model.targetWindowGeometry?.id == window.windowID else { throw CaptureError.message("PDF target changed; no automatic events sent") }
        guard model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Existing automatic permission unavailable") }
        for _ in 0..<600 where model.frames < frameLimit {
            if model.paused { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard model.frames == frameLimit, images.count == frameLimit else {
            let rejected = try? await CaptureEngine().visibleRegion(world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), screen: screen, content: content, target: window)
            try Task.checkCancellation()
            try await Task.detached {
                if let rejected { try NativeScrollDiagnostic.writePNG(rejected, to: root.appendingPathComponent("native-rejected-current.png")) }
                else {
                    try JSONSerialization.data(withJSONObject: ["imageOmitted": true, "reason": "Complete target visibility was not verified"]).write(to: root.appendingPathComponent("native-rejected-image-omitted.json"), options: .atomic)
                }
                let geometry = try PreviewDocumentProbe.inspect(pid: owner.processID, id: id, source: source)
                try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted]).write(to: root.appendingPathComponent("native-rejected-geometry.json"), options: .atomic)
            }.value
            throw CaptureError.message("PDF capture stopped at \(model.frames): \(model.warning ?? "none")")
        }
        if !model.paused { model.togglePause() }
        let destination = root.appendingPathComponent("native-\(id).png")
        await model.finish(output: .file(destination))
        guard let rendered, !model.active else { throw CaptureError.message("PDF capture export failed") }
        let accepted = images, anchors = positions
        let verification = try await Task.detached { try NativeScrollDiagnostic.verify(accepted, anchors: anchors, scale: scale, reverse: reverse, output: rendered, root: root) }.value
        guard verification["differingPixels"] as? Int == 0 else { throw CaptureError.message("PDF capture differs from page-coordinate oracle: \(verification)") }
        let low = min(positions.first!, positions.last!), high = max(positions.first!, positions.last!)
        // Express the entire screenshot range in the starting PDF coordinates.
        let displacement = positions.last!-positions.first!
        let range = reverse ? bounds.offsetBy(dx: 0, dy: -displacement).union(bounds) : bounds.union(bounds.offsetBy(dx: 0, dy: -displacement))
        let pagesTouched = initialPages.enumerated().filter { $0.element.intersects(range) }.map { $0.offset }
        guard pagesTouched.count >= 2 else { throw CaptureError.message("PDF case did not cross a page boundary; preserve output but do not count success") }
        return ["fixtureCase": id, "app": owner.bundleIdentifier, "direction": reverse ? "reverse" : "forward", "frames": images.count, "independentPagePositions": positions, "pagePositionRange": [low, high], "pagesTouched": pagesTouched, "verification": verification, "output": destination.path, "clipboardTouched": false, "userContentUsed": false]
    }
    private nonisolated static func pages(_ geometry: [String: Any]) throws -> [CGRect] {
        let rows = geometry["elements"] as? [[String: Any]] ?? []
        let values = rows.filter { $0["role"] as? String == "AXPage" }.sorted { ($0["matchesOwnedPage"] as? Int ?? -1) < ($1["matchesOwnedPage"] as? Int ?? -1) }
        guard values.count == 6, values.enumerated().allSatisfy({ $0.element["matchesOwnedPage"] as? Int == $0.offset }) else { throw CaptureError.message("Independent PDF page mapping missing") }
        return try values.map { try box($0) }
    }
    private nonisolated static func box(_ row: [String: Any]) throws -> CGRect {
        guard let b = row["bounds"] as? [Double], b.count == 4 else { throw CaptureError.message("PDF AX bounds unavailable") }
        return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
    }
    private nonisolated static func viewport(_ geometry: [String: Any]) throws -> CGRect {
        guard let rows = geometry["elements"] as? [[String: Any]],
              let first = rows.first(where: { $0["role"] as? String == "AXPage" && $0["matchesOwnedPage"] as? Int == 0 }) else { throw CaptureError.message("PDF body page missing") }
        var parent = first["parent"] as? Int ?? -1
        while parent >= 0, parent < rows.count, rows[parent]["role"] as? String != kAXScrollAreaRole { parent = rows[parent]["parent"] as? Int ?? -1 }
        guard parent >= 0, parent < rows.count else { throw CaptureError.message("PDF document scroll area missing") }
        let area = try box(rows[parent]), page = try box(first)
        var right = min(area.maxX,page.maxX), bottom = area.maxY
        for row in rows where row["parent"] as? Int == parent && row["role"] as? String == kAXScrollBarRole {
            let bar = try box(row)
            if bar.width > bar.height { bottom = min(bottom,bar.minY) } else { right = min(right,bar.minX) }
        }
        let result = CGRect(x: ceil(max(area.minX,page.minX)), y: ceil(area.minY), width: floor(right)-ceil(max(area.minX,page.minX)), height: floor(bottom)-ceil(area.minY))
        guard result.width > 100, result.height > 100 else { throw CaptureError.message("PDF document viewport too small") }
        return result.insetBy(dx: 1, dy: 1)
    }
}
