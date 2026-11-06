import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Captures only an explicitly named loopback fixture window, through the
/// production scroll session. Does not launch, navigate or close browsers.
@MainActor
enum BrowserScrollDiagnostic {
    static func run(root: URL) async throws -> [String: Any] {
        guard let address = ProcessInfo.processInfo.environment["DESKCAPTURE_BROWSER_FIXTURE_URL"],
              let base = URL(string: address), base.scheme == "http", base.host == "127.0.0.1",
              let id = ProcessInfo.processInfo.environment["DESKCAPTURE_BROWSER_CASE"],
              id.allSatisfy({ $0.isLetter || $0.isNumber }), !id.isEmpty else {
            throw CaptureError.message("An explicit local browser fixture and case ID are required")
        }
        func state() async throws -> [String: Any] {
            let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("state/\(id)"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CaptureError.message("Browser fixture state missing") }
            return value
        }
        let initial = try await state()
        guard initial["ready"] as? Bool == true, let run = initial["run"] as? String,
              let scale = initial["scale"] as? Double,
              let axisName = initial["axis"] as? String,
              let reverse = initial["reverse"] as? Bool,
              let fixed = initial["fixed"] as? Bool else { throw CaptureError.message("Browser fixture not ready") }
        let title = "DC Fixture \(run) \(id)"
        let content = try await CaptureEngine().content()
        let matches = content.windows.filter { $0.isOnScreen && ($0.title?.contains(title) ?? false) && $0.windowLayer == 0 }
        guard matches.count == 1, let target = matches.first, let owner = target.owningApplication,
              ["com.google.Chrome", "com.apple.Safari"].contains(owner.bundleIdentifier) else { throw CaptureError.message("Exactly one owned Safari/Chrome fixture window is required") }
        let bounds = try await Task.detached { try fixtureBounds(pid: owner.processID, title: title) }.value
        let visibility = await Task.detached { () -> (Bool, [String: Any]) in
            guard let info = CaptureWindowInfo.read(target.windowID) else { return (false, ["error": "Expected window geometry unavailable"]) }
            let windowBounds = info.frame
            let items = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            let first = items.first { item in
                guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let value = item[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: value as CFDictionary) else { return false }
                return frame.contains(point)
            }
            let firstID = first?[kCGWindowNumber as String] as? UInt32
            let firstPID = first?[kCGWindowOwnerPID as String] as? Int32
            let beneathSystemDock = items.first { item in
                guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let value = item[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: value as CFDictionary), frame.contains(point) else { return false }
                let pid = item[kCGWindowOwnerPID as String] as? Int32
                return pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path } != "/System/Library/CoreServices/Dock.app"
            }
            let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.12)
            var hit: AXUIElement?, hitPID: pid_t = 0
            if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit { AXUIElementGetPid(hit, &hitPID) }
            let ax = ScrollContainerDetector.globalTargetPoint(area: bounds, avoiding: [], pid: owner.processID,
                                                               windowID: target.windowID, windowFrame: windowBounds) != nil
            let trace: [String: Any] = ["expectedWindowID": target.windowID, "expectedPID": owner.processID,
                                       "firstWindowID": firstID ?? 0, "firstPID": firstPID ?? 0,
                                       "beneathDockWindowID": beneathSystemDock?[kCGWindowNumber as String] ?? 0,
                                       "beneathDockPID": beneathSystemDock?[kCGWindowOwnerPID as String] ?? 0,
                                       "AXHitPID": hitPID,
                                       "fixtureBounds": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                                       "windowBounds": [windowBounds.minX, windowBounds.minY, windowBounds.width, windowBounds.height],
                                       "globalAXConfirmed": ax]
            // A visible original WindowServer window is the primary proof. AX
            // is only needed to adjudicate a transparent system input surface.
            return (firstID == target.windowID || ax, trace)
        }.value
        if let folder = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] {
            try JSONSerialization.data(withJSONObject: visibility.1, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: folder).appendingPathComponent("browser-visibility.json"), options: .atomic)
        }
        guard visibility.0 else { throw CaptureError.message("Owned browser fixture is occluded; raise its test window before capturing") }
        guard let screen = NSScreen.screens.first(where: {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return $0.frame.contains(CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height))
        }), abs(screen.backingScaleFactor - scale) < 0.01 else { throw CaptureError.message("Browser fixture scale or screen mismatch") }
        let world = CGRect(x: bounds.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - bounds.maxY, width: bounds.width, height: bounds.height)
        let axis: ScrollAxis = axisName == "horizontal" ? .horizontal : .vertical
        let direction: ScrollDirection = reverse ? .reverse : .forward
        // Verify the production selection/coordinator/HUD path as well as the
        // stitching session below. Never deliver a fixture to the user's board.
        var productionEntryVerified = false
        if axis == .vertical {
            let board = NSPasteboard(name: .init("DeskCapture-browser-entry-\(UUID())"))
            defer { board.releaseGlobally() }
            let app = AppCoordinator(store: CaptureStore(directory: root.appendingPathComponent("browser-entry-history")),
                                     imagePasteboard: board, registerHotKeys: false)
            defer { app.cancelCapture(); app.dashboard?.close() }
            app.automaticScrolling = false
            app.scrollSelectionForDiagnostics = world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            var confirmed = false
            app.onSelectionPresented = { confirmed = app.confirmScrollSelectionForDiagnostics() }
            app.start(.scrolling, scrollDirection: direction)
            for _ in 0..<240 {
                if confirmed && !app.isCapturing { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            productionEntryVerified = confirmed && app.scrollCapture.active && app.scrollCapture.frames == 1
                && app.scrollCapture.targetWindowGeometry?.id == target.windowID && app.scrollOutlineVisibleForDiagnostics
            await app.cancelScrollCapture()
            guard productionEntryVerified, !app.scrollOutlineVisibleForDiagnostics else {
                throw CaptureError.message("Chrome/Safari 长图实际入口未就绪：\(app.notice ?? app.scrollCapture.warning ?? "首帧或边框缺失")")
            }
        }
        let model = ScrollCapture()
        defer { Task { await model.cancel() } }
        var rendered: CGImage?
        model.onFinish = { image, _ in rendered = image }
        try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), content: content, automatic: false, axis: axis, direction: direction)
        guard model.targetWindowGeometry?.id == target.windowID else {
            await model.cancel()
            throw CaptureError.message("Browser target changed during start; no automatic events sent")
        }
        let containerCount = model.containers.count
        guard model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Existing automatic scroll permission unavailable") }
        let expectedEdges = fixed ? ScrollFixedEdges(leading: Int(36 * scale), trailing: Int(28 * scale)) : .none
        for _ in 0..<600 where model.frames < 4 {
            if let suggested = model.suggestedFixedEdges {
                guard fixed, suggested == expectedEdges else { throw CaptureError.message("Browser fixed edges mismatch: \(suggested)") }
                await model.configureFixedEdges(suggested)
                guard model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Browser resume failed") }
            } else if model.paused { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard model.frames >= 4 else { throw CaptureError.message("Browser stopped at \(model.frames) frames: \(model.warning ?? "no warning")") }
        if !model.paused { model.togglePause() }
        // Proven fixed bars may be resolved by the worker without a manual
        // suggestion. Verify the resulting state for both resolution paths.
        guard model.fixedEdges == expectedEdges else { throw CaptureError.message("Browser resolved fixed edges mismatch: \(model.fixedEdges), expected \(expectedEdges)") }
        let confirmed = fixed && model.fixedEdges == expectedEdges
        let capturedFrames = model.frames, resultWidth = model.preview.width, resultHeight = model.preview.height
        let primary = axis == .vertical ? resultHeight : resultWidth
        let afterPause = try await state()
        let output = root.appendingPathComponent("browser-\(id).png")
        await model.finish(output: .file(output))
        guard let rendered, !model.active else { throw CaptureError.message("Browser export failed") }
        guard let events = afterPause["wheelEvents"] as? [[String: Any]], events.count >= capturedFrames - 1 else { throw CaptureError.message("Independent wheel transcript missing; output: \(output.path)") }
        let completed = Array(events.prefix(capturedFrames - 1))
        guard completed.allSatisfy({ $0["applied"] as? Bool == true }),
              let lastPosition = completed.last?["position"] as? Double,
              let initialPosition = initial[axis == .vertical ? "scrollY" : "scrollX"] as? Double else { throw CaptureError.message("Capture committed before the requested browser wheel completed; output: \(output.path)") }
        // The production matcher may reduce speed after a transient CSS repaint.
        // Browser-owned applied positions, rather than a constant speed assumption,
        // provide the independent output range and retain that legitimate behavior.
        let displacement = Int((abs(lastPosition - initialPosition) * scale).rounded())
        guard primary == Int((axis == .vertical ? bounds.height : bounds.width) * scale) + displacement,
              !fixed || confirmed else { throw CaptureError.message("Browser image length mismatch: \(primary), initial \(initialPosition), end \(lastPosition), frames \(capturedFrames), events \(completed); output: \(output.path)") }
        let finalState = try await state()
        guard let pendingMaximum = finalState["maxPending"] as? Int, pendingMaximum <= 1 else {
            throw CaptureError.message("Browser delayed wheel requests overlapped")
        }
        let low = Int((min(initialPosition, lastPosition) * scale).rounded())
        let assetName = axis == .vertical ? "vertical.png" : "horizontal.png"
        let (asset, _) = try await URLSession.shared.data(from: base.appendingPathComponent(assetName))
        let leading = fixed ? Int(36 * scale) : 0, trailing = fixed ? Int(28 * scale) : 0
        let error = try await Task.detached(priority: .userInitiated) { () throws -> Double in
            guard let source = CGImageSourceCreateWithData(asset as CFData, nil), let page = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.message("Independent browser oracle unreadable") }
            let bodyLength = primary - leading - trailing
            let crop = axis == .vertical ? CGRect(x: 0, y: low, width: resultWidth, height: bodyLength) : CGRect(x: low, y: 0, width: bodyLength, height: resultHeight)
            guard let body = page.cropping(to: crop),
                  let context = CGContext(data: nil, width: resultWidth, height: resultHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("Independent browser oracle range invalid") }
            context.draw(body, in: axis == .vertical ? CGRect(x: 0, y: trailing, width: resultWidth, height: bodyLength) : CGRect(x: leading, y: 0, width: bodyLength, height: resultHeight))
            if fixed {
                guard axis == .vertical else { throw CaptureError.message("Horizontal fixed-edge browser oracle not yet configured") }
                context.draw(WorkflowCorpus.texture(width: resultWidth, height: leading, seed: 777), in: CGRect(x: 0, y: resultHeight - leading, width: resultWidth, height: leading))
                context.draw(WorkflowCorpus.texture(width: resultWidth, height: trailing, seed: 778), in: CGRect(x: 0, y: 0, width: resultWidth, height: trailing))
            }
            guard let expected = context.makeImage() else { throw CaptureError.message("Browser oracle render failed") }
            let a = ScrollMatcher.grayscale(rendered), b = ScrollMatcher.grayscale(expected)
            guard a.count == b.count, !a.isEmpty else { throw CaptureError.message("Browser oracle dimensions differ") }
            return Double(zip(a,b).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }) / Double(a.count)
        }.value
        guard error <= 2 else { throw CaptureError.message("Browser output order/pixels differ from original page: mean error \(error)") }
        return ["fixtureCase": id, "browser": owner.bundleIdentifier, "fixtureTitle": title, "axis": axisName,
                "direction": direction.rawValue, "productionEntryVerified": productionEntryVerified, "containers": containerCount, "frames": capturedFrames,
                "pixels": "\(resultWidth)x\(resultHeight)", "meanGrayError": error, "fixedEdgesConfirmed": confirmed,
                "initialState": initial, "finalState": finalState, "output": output.path, "clipboardTouched": false, "userContentUsed": false]
    }
    private nonisolated static func fixtureBounds(pid: pid_t, title: String) throws -> CGRect {
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        func bounds(_ element: AXUIElement) -> CGRect? {
            guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }
        let application = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(application, 0.12)
        guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: { (value($0, kAXTitleAttribute) as? String)?.contains(title) == true }) else { throw CaptureError.message("Owned browser AX window missing") }
        var queue = [window], examined = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !queue.isEmpty, examined < 1500, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation(); let element = queue.removeFirst(); examined += 1; AXUIElementSetMessagingTimeout(element, 0.12)
            if [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains(where: { value(element, $0) as? String == title }),
               let rectangle = bounds(element), abs(rectangle.width - 480) < 1, abs(rectangle.height - 300) < 1 { return rectangle }
            queue += value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        throw CaptureError.message("Labelled browser fixture rectangle not found; no guessed coordinates used")
    }
}
