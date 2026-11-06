import AppKit
import ApplicationServices

/// Runs the real capture entry against an owned changing viewport. No user
/// browser, clipboard, preferences or media is used as a fixture.
@MainActor
enum DynamicScrollDiagnostic {
    static func run(root: URL, automatic: Bool) async throws -> [String: Any] {
        if automatic && !AXIsProcessTrusted() { throw CaptureError.message("Existing AX permission required") }
        let name = automatic ? "automatic" : "manual"
        let metadata = root.appendingPathComponent("dynamic-\(name).json")
        let control = metadata.appendingPathExtension("motion")
        let fixture = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ScrollFixtureTarget.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true; configuration.activates = true
        configuration.arguments = [metadata.path, "--safe-position", "--motion-control", "--initial-y=1600"]
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { configuration.environment = ["CFFIXED_USER_HOME": home] }
        let app = try await NSWorkspace.shared.openApplication(at: fixture, configuration: configuration)
        defer { app.terminate() }
        func state() throws -> [String: Any] {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
            guard let value, value["pid"] as? Int32 == app.processIdentifier else { throw CaptureError.message("Dynamic fixture identity changed") }
            return value
        }
        var timeoutModel: ScrollCapture?
        func wait(_ seconds: Double, stage: String, until condition: () throws -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !(try condition()) {
                guard ProcessInfo.processInfo.systemUptime < end else {
                    throw CaptureError.message("Dynamic \(name) timed out at \(stage): paused=\(timeoutModel?.paused.description ?? "n/a"), frames=\(timeoutModel?.frames ?? 0), warning=\(timeoutModel?.warning ?? "none"), fixture=\(String(describing: try? state()))")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await wait(8, stage: "metadata") { FileManager.default.fileExists(atPath: metadata.path) }
        let initial = try state()
        guard let box = initial["rect"] as? [Double], box.count == 4,
              let scale = initial["scale"] as? Double else { throw CaptureError.message("Dynamic fixture geometry missing") }
        let world = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(world) }) else { throw CaptureError.message("Dynamic fixture outside screen") }
        let content = try await CaptureEngine().content()
        guard let target = content.windows.first(where: { $0.isOnScreen && $0.owningApplication?.processID == app.processIdentifier }) else { throw CaptureError.message("Owned dynamic target missing") }
        let model = ScrollCapture()
        timeoutModel = model
        defer { Task { await model.cancel() } }
        try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), content: content, automatic: false)
        model.togglePause()
        let frames = model.frames, height = model.preview.height
        // The manual fixture itself scrolls; automatic mode must issue its own
        // wheel once and hold its position while the picture keeps changing.
        try Data((automatic ? "" : "1713").utf8).write(to: control, options: .atomic)
        try await wait(3, stage: "motion-start") { try state()["motionActive"] as? Bool == true }
        guard model.setAutomatic(automatic, requestPermission: false) else { throw CaptureError.message("Dynamic capture resume unavailable") }
        try await wait(15, stage: "motion-pause") { model.paused }
        let moving = try state()
        let pauseReason = model.warning ?? ""
        let visibilityRejected = DiagnosticScrollMessages.matches(pauseReason, reason: .visibility)
        // Manual sampling can observe two matching animation frames. The seam
        // verifier must then reject them against the retained page; this is an
        // equally safe stop and still has to pass exact recovery below.
        let seamRejected = !automatic && model.needsSeamRecovery
        let motionWheels = moving["completedScrolls"] as? Int
        guard DiagnosticScrollMessages.matches(pauseReason, reason: .changing) || visibilityRejected || seamRejected,
              model.frames == frames, model.preview.height == height,
              !model.waitingForStableFrame,
              !automatic || motionWheels == 1 || (visibilityRejected && motionWheels == 0) else {
            throw CaptureError.message("Broad motion committed or pause lost content: \(model.warning ?? "none"), frames=\(model.frames)/\(frames)")
        }
        let motionTicks = moving["motionTick"] as? Int ?? 0
        try FileManager.default.removeItem(at: control)
        try await wait(3, stage: "motion-stop") { try state()["motionActive"] as? Bool == false }
        // Removing a view is not a WindowServer presentation fence. Require
        // the restored generated page itself before exercising explicit Resume;
        // this neither retries a failed Resume nor weakens capture validation.
        let restoredState = try state()
        guard let restoredY = restoredState["currentY"] as? Double else { throw CaptureError.message("Restored fixture position missing") }
        let expected = try await Task.detached(priority: .utility) { () throws -> CGImage in
            let page = WorkflowCorpus.texture(width: Int(box[2] * scale), height: Int(2500 * scale), seed: 42)
            guard let crop = page.cropping(to: CGRect(x: 0, y: Int((restoredY * scale).rounded()), width: Int(box[2] * scale), height: Int(box[3] * scale))) else { throw CaptureError.message("Restored fixture crop invalid") }
            return crop
        }.value
        let engine = CaptureEngine()
        var repaintVerified = false
        for _ in 0..<12 {
            try Task.checkCancellation()
            do {
                let image = try await engine.visibleRegion(world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), screen: screen, content: content, target: target)
                repaintVerified = try await Task.detached(priority: .utility) { try ScrollFrameVisibility.matches(display: image, target: expected) }.value
                if repaintVerified { break }
            } catch is CancellationError { throw CancellationError() }
            catch { /* No unverified pixels are retained. */ }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard repaintVerified else { throw CaptureError.message("Owned fixture did not present the restored page before Resume") }
        // Begin saving during an otherwise running session, then emulate
        // cancelling the save from this app's focused control window.
        model.togglePause()
        guard model.beginFileSelection(), model.paused, model.choosingFile else { throw CaptureError.message("Save did not suspend dynamic capture") }
        // Simulate pressing the capture app's Resume control: its own window
        // takes focus, outside the owned capture area. No foreign app is driven.
        let focusWindow = NSWindow(contentRect: CGRect(x: screen.frame.maxX - 300, y: screen.frame.minY + 40, width: 260, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false; focusWindow.title = "DeskCapture generated Resume focus fixture"
        focusWindow.contentView = NSTextField(labelWithString: "Generated capture control")
        focusWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { focusWindow.close() }
        try await wait(3, stage: "control-focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
        model.onDiagnosticAcceptedFrame = { _, _ in true }
        if automatic { await model.completeSegmentSelection(nil) }
        else { await model.completeFileSelection(nil) }
        guard !model.choosingFile else { throw CaptureError.message("Cancelled save left capture blocked") }
        try await wait(3, stage: "target-focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        do { try await wait(8, stage: "resumed-frame") { model.paused && model.frames > frames } }
        catch { throw CaptureError.message("Dynamic \(name) recovery timed out: paused=\(model.paused), frames=\(model.frames), height=\(model.preview.height), warning=\(model.warning ?? "none"), state=\(try state())") }
        let final = try state()
        guard let y = final["currentY"] as? Double, y > 1600,
              model.frames == frames + 1,
              model.preview.height == height + Int(((y - 1600) * scale).rounded()),
              final["maxPendingScrolls"] as? Int == (automatic ? 1 : 0) else {
            throw CaptureError.message("Dynamic recovery lost overlap or changed wheel count")
        }
        let expectedWidth = model.preview.width, expectedHeight = model.preview.height
        let destination = root.appendingPathComponent("dynamic-\(name)-recovered.png")
        await model.finish(output: .file(destination))
        guard !model.active else { throw CaptureError.message(model.warning ?? "Dynamic recovery export failed") }
        try await Task.detached(priority: .utility) {
            let image = try CaptureImageRead.load(destination)
            guard image.width == expectedWidth, image.height == expectedHeight else { throw CaptureError.message("Dynamic recovery PNG unreadable or wrong size") }
        }.value
        return ["mode": name, "motionTicks": motionTicks, "motionWheelRequests": motionWheels ?? 0, "broadMotionRejected": true,
                "pauseReason": pauseReason, "visibilityRejectedBeforeStability": visibilityRejected,
                "pausedWithOriginalSegments": true, "restoredPagePixelsVerifiedBeforeResume": repaintVerified, "targetFocusRestoredOnResume": true, "resumedAfterStable": true,
                "cancelledSaveKeptSession": true, "resumeAction": automatic ? "cancel-segment-save" : "cancel-file-save",
                "recoveredFrames": frames + 1, "height": expectedHeight,
                "output": destination.path, "userContentUsed": false, "clipboardTouched": false]
    }
}
