import AppKit
import AVFoundation
import SwiftUI
import ScreenCaptureKit

/// Explicit developer-only diagnostics. All outputs and preferences are isolated.
@MainActor
final class QualityDiagnostics {
    private var rows: [[String: Any]] = []
    private var executableSHA256 = ""
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-quality-\(UUID())", isDirectory: true)
    private var heartbeat: Timer?
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private var maximumGap = 0.0
    private var phase = ""
    private var stalls: [[String: Any]] = []
    private var window: NSWindow?
    private var captureFixture: NSRunningApplication?
    private var preferences: UserDefaults!
    private let suite = "DeskCapture-quality-\(UUID())"
    private func beat() {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastBeat
        if gap > 0.2 { stalls.append(["phase": phase, "seconds": gap, "endUptime": now]) }
        maximumGap = max(maximumGap, gap); lastBeat = now
    }
    private func check(_ name: String, _ body: () async throws -> [String: Any]) async {
        if CommandLine.arguments.contains("--dynamic-scroll-diagnostic"), !name.hasPrefix("scroll-dynamic-") { return }
        if CommandLine.arguments.contains("--whole-page-scroll-diagnostic"), !name.hasPrefix("whole-page-scroll-") { return }
        if CommandLine.arguments.contains("--scroll-visibility-diagnostic"),name != "scroll-full-region-visibility" { return }
        if CommandLine.arguments.contains("--long-recording-diagnostic"), name != "long-recording-resources" { return }
        if CommandLine.arguments.contains("--native-scroll-diagnostic"), name != "real-native-scroll-fixture" { return }
        if CommandLine.arguments.contains("--native-document-probe"), name != "native-document-geometry" { return }
        if CommandLine.arguments.contains("--browser-scroll-diagnostic"), name != "real-browser-scroll-fixture" { return }
        if CommandLine.arguments.contains("--stream-export-diagnostic"), name != "streamed-long-beyond-old-limits" { return }
        if CommandLine.arguments.contains("--upward-scroll-diagnostic"), name != "native-upward-scroll-generated-target", !name.hasPrefix("native-scroll-") { return }
        maximumGap = 0; stalls = []; phase = name; lastBeat = ProcessInfo.processInfo.systemUptime
        let start = lastBeat
        do {
            var row = try await body(); beat()
            row["case"] = name; row["success"] = true
            row["seconds"] = ProcessInfo.processInfo.systemUptime - start
            row["maxMainThreadGapSeconds"] = maximumGap; row["stalls"] = stalls
            if maximumGap > 0.5 { row["success"] = false; row["error"] = "Main thread stalled for more than 500 ms" }
            rows.append(row)
        } catch {
            rows.append(["case": name, "success": false, "error": String(describing: error), "seconds": ProcessInfo.processInfo.systemUptime - start])
        }
        writeReport(finished: false)
    }
    private func writeReport(finished: Bool) {
        let report: [String: Any] = ["finished": finished, "success": finished && rows.allSatisfy { $0["success"] as? Bool == true },
                                   "cases": rows, "artifacts": root.path,
                                   "scope": CommandLine.arguments.contains("--dynamic-scroll-diagnostic") ? "dynamic-scroll-debug-only" : CommandLine.arguments.contains("--whole-page-scroll-diagnostic") ? "whole-page-scroll-debug-only" : CommandLine.arguments.contains("--scroll-visibility-diagnostic") ? "visibility-debug-only" : CommandLine.arguments.contains("--long-recording-diagnostic") ? "long-recording-resources-only" : CommandLine.arguments.contains("--native-scroll-diagnostic") ? "native-debug-only" : CommandLine.arguments.contains("--native-document-probe") ? "native-geometry-debug-only" : CommandLine.arguments.contains("--browser-scroll-diagnostic") ? "browser-debug-only" : CommandLine.arguments.contains("--stream-export-diagnostic") ? "stream-debug-only" : CommandLine.arguments.contains("--upward-scroll-diagnostic") ? "scroll-debug-only" : "full",
                                   "runID": ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_RUN_ID"] ?? "legacy",
                                   "executableSHA256": executableSHA256,
                                   "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
                                   "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let directory = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] ?? "/tmp"
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("deskcapture-quality-diagnostic.json"), options: .atomic)
        }
    }
    func run() async {
        do {
            guard let executable = Bundle.main.executableURL else { throw CaptureError.message("无法读取当前诊断可执行文件。") }
            executableSHA256 = try await Task.detached(priority: .utility) { try ArtifactIdentity.sha256(executable) }.value
        } catch {
            rows.append(["case": "candidate-identity", "success": false, "error": error.localizedDescription])
            writeReport(finished: true); NSApp.terminate(nil); return
        }
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "recordCamera"); preferences.set(30, forKey: "recordFPS")
        preferences.set(false, forKey: "recordShortcuts"); preferences.set(false, forKey: "recordMicrophone")
        // Menus and save panels use nested tracking/modal run loops. A default-
        // mode timer would count the time the user keeps a menu open as a stall.
        // Execute on the main run loop itself so real blocking work still counts.
        heartbeat = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
        defer { heartbeat?.invalidate(); preferences.removePersistentDomain(forName: suite); window?.close(); captureFixture?.terminate() }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) } catch { return }
        if CommandLine.arguments.contains("--whole-page-scroll-diagnostic") {
            for reverse in [false, true] {
                await check("whole-page-scroll-\(reverse ? "reverse" : "forward")") {
                    try await WholePageScrollDiagnostic.run(root: self.root, reverse: reverse)
                }
            }
        }
        for automatic in [false, true] {
            await check("scroll-dynamic-\(automatic ? "automatic" : "manual")-recovery") {
                try await DynamicScrollDiagnostic.run(root: self.root, automatic: automatic)
            }
        }
        await check("daily-history-copy-clipboard-edit") { try await DailyCaptureDiagnostic.run(root: self.root) }
        await check("scroll-full-region-visibility") { try await ScrollVisibilityDiagnostic.run(root:self.root) }
        await check("native-screen-region-window-capture") {
            let owned = try await self.prepareCaptureFixture()
            let engine = CaptureEngine(), content = try await engine.content()
            let snapshots = try await engine.snapshots(content: content)
            let screen = try self.availableScreen(in: content)
            guard let snapshot = snapshots.first else { throw CaptureError.message("No screen snapshot") }
            let rect = CGRect(x: 20, y: 100, width: 600, height: 340)
            let region = try await engine.region(rect, screen: screen, content: content)
            guard region.width >= 600 else { throw CaptureError.message("Region has incorrect dimensions") }
            var row: [String: Any] = ["displays": snapshots.count, "fullScreenPixels": "\(snapshot.image.width)x\(snapshot.image.height)", "regionPixels": "\(region.width)x\(region.height)"]
            if let target = content.windows.first(where: { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width > 300 && $0.frame.height > 200 && $0.owningApplication?.processID == owned.processIdentifier }) {
                let image = try await engine.capture(window: target)
                row["windowPixels"] = "\(image.width)x\(image.height)"
            } else { throw CaptureError.message("No owned generated window to verify") }
            return row
        }
        await check("workflow-region-input-confirm-cancel-isolation") {
            guard let fixture = self.captureFixture, !fixture.isTerminated else { throw CaptureError.message("Owned generated capture background unavailable") }
            fixture.activate(options: [])
            let board = NSPasteboard(name: .init("DeskCapture-workflow-quality-\(UUID())"))
            board.setString("workflow input sentinel", forType: .string)
            defer { board.releaseGlobally() }
            let store = CaptureStore(directory: self.root.appendingPathComponent("workflow-input-history"))
            let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
            app.workflowInputRectForDiagnostics = CGRect(x: 40, y: 40, width: 180, height: 120)
            let oldRegion = AppPreferences.standard.data(forKey: "lastSelection")
            let oldDesktop = AppPreferences.standard.data(forKey: "lastDesktopRegion")
            var presented = false, replies = 0, selected: CGImage?, failure: Error?
            app.onSelectionPresented = { presented = true }
            defer { app.cancelCapture() }
            let first = try app.pickWorkflowInput(.region) { response in
                replies += 1
                switch response { case .success(let image): selected = image; case .failure(let error): failure = error }
            }
            for _ in 0..<400 where !presented && failure == nil { try await Task.sleep(for: .milliseconds(25)) }
            guard presented, app.confirmWorkflowInputForDiagnostics() else { throw CaptureError.message("Workflow input picker was not ready: \(String(describing: failure))") }
            for _ in 0..<400 where replies == 0 { try await Task.sleep(for: .milliseconds(25)) }
            guard replies == 1, let selected, selected.width >= 180, selected.height >= 120, !app.isCapturing, failure == nil else { throw CaptureError.message("Confirmed workflow input did not finish exactly once") }
            presented = false; replies = 0; failure = nil
            let second = try app.pickWorkflowInput(.region) { response in
                replies += 1
                if case .failure(let error) = response { failure = error }
            }
            app.cancelWorkflowInput(first)
            guard app.isCapturing else { throw CaptureError.message("Expired input owner cancelled a later selection") }
            app.cancelWorkflowInput(second)
            try await Task.sleep(for: .milliseconds(150))
            guard replies == 1, failure is CancellationError, !app.isCapturing,
                  !app.confirmWorkflowInputForDiagnostics(), store.records.isEmpty,
                  board.string(forType: .string) == "workflow input sentinel", board.data(forType: .png) == nil,
                  AppPreferences.standard.data(forKey: "lastSelection") == oldRegion,
                  AppPreferences.standard.data(forKey: "lastDesktopRegion") == oldDesktop else { throw CaptureError.message("Workflow input cancellation or delivery isolation failed") }
            return ["regionPixels": "\(selected.width)x\(selected.height)", "confirmedReplies": 1,
                    "cancelledReplies": replies, "namedPasteboardPreserved": true, "historyPreserved": true,
                    "selectionPreferencesPreserved": true, "expiredOwnerRejected": true,
                    "scope": "real region picker confirm; pending picker cancel; window selection requires separate entry verification"]
        }
        await check("large-image-history-project-ocr-exports") {
            let image = try self.fixture(width: 3840, height: 2160)
            let store = CaptureStore(directory: self.root.appendingPathComponent("captures"))
            let document = AnnotationDocument(image: image)
            document.add(document.makeMark(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)]))
            let record = try await store.addAsync(image, mode: .region, document: document, backingScale: 2)
            let restored = CaptureStore(directory: store.directory)
            guard restored.records.count == 1, try restored.document(for: record)?.marks.count == 1 else { throw CaptureError.message("History/project roundtrip failed") }
            let sample = try self.fixture(width: 1200, height: 500)
            let text = try await CaptureEngine.recognize(sample)
            guard text.contains("DeskCapture") else { throw CaptureError.message("OCR did not recognize fixture") }
            try await Task.detached {
                for ext in ["png", "jpg", "tiff", "heic", "pdf"] {
                    try CaptureImageExport.write(sample, to: self.root.appendingPathComponent("image.\(ext)"))
                }
            }.value
            return ["imagePixels": "3840x2160", "ocr": text, "formats": 5]
        }
        await check("image-cleanup-strip-trim-foreground-cancel") {
            let image = try self.fixture(width: 3840, height: 2160)
            let plan = ImageCleanupPlan(strips: [ImageStrip(axis: .rows, start: 100, end: 200),
                                               ImageStrip(axis: .columns, start: 2500, end: 2600)])
            let shortened = try await Task.detached { try CaptureImageCleanup.render(image, plan: plan) }.value
            guard shortened.width == 3740, shortened.height == 2060 else { throw CaptureError.message("Incorrect shortened image size") }
            let trimmed = try await Task.detached { try CaptureImageCleanup.trim(shortened) }.value
            guard trimmed.width < shortened.width, trimmed.height < shortened.height else { throw CaptureError.message("Whitespace was not trimmed") }
            let fruit = try Self.cleanupFixture()
            let foreground = try await Task.detached { try CaptureImageCleanup.foreground(fruit) }.value
            let output = self.root.appendingPathComponent("foreground.png")
            try await Task.detached { try CaptureImageExport.write(foreground, to: output) }.value
            let restored = try await Task.detached { try CaptureImageRead.load(output) }.value
            guard restored.width == fruit.width, restored.height == fruit.height,
                  Self.alpha(restored, at: .zero) == 0, Self.alpha(restored, at: CGPoint(x: 400, y: 300)) > 200 else {
                throw CaptureError.message("Foreground or transparent PNG did not survive export")
            }
            let model = ImageCleanupModel(source: image)
            model.update(plan); model.cancel()
            try await Task.sleep(for: .milliseconds(200))
            guard model.result == nil, !model.busy else { throw CaptureError.message("Cancelled image cleanup restored output") }
            return ["sourcePixels": "3840x2160", "shortenedPixels": "3740x2060", "trimmedPixels": "\(trimmed.width)x\(trimmed.height)",
                    "foregroundPixels": "\(restored.width)x\(restored.height)", "transparentPNG": true, "cancelled": true]
        }
        await check("native-long-image-start-save-cancel") {
            let owned = try await self.prepareCaptureFixture()
            owned.activate(options: [.activateAllWindows])
            try await Task.sleep(for: .milliseconds(300))
            let content = try await CaptureEngine().content(), model = ScrollCapture()
            let screen = try self.availableScreen(in: content)
            let point = CGPoint(x: screen.frame.minX + 320,
                                y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.minY - 270)
            guard let target = content.windows.first(where: {
                $0.windowLayer == 0 && $0.isOnScreen && $0.frame.contains(point)
                    && $0.owningApplication?.processID == owned.processIdentifier
            }) else { throw CaptureError.message("Owned generated long-image target unavailable") }
            var completions = 0
            model.onFinish = { _, _ in completions += 1 }
            let rect = CGRect(x: 20, y: 100, width: 600, height: 340)
            try await model.start(screen: screen, rect: rect, content: content, automatic: false, targetWindowID: target.windowID)
            guard model.frames == 1, !model.processingSegment else { throw CaptureError.message("Long image first frame missing") }
            model.togglePause()
            self.present(ScrollHUD(scroll: model, finish: {}, save: {}, cancel: {}))
            let width = model.preview.width, height = model.preview.height
            let destination = self.root.appendingPathComponent("native-scroll.png")
            await model.finish(output: .file(destination))
            guard !model.active, completions == 1,
                  let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == width, image.height == height else { throw CaptureError.message("Native long image export failed") }
            let starting = Task { try await model.start(screen: screen, rect: rect, content: content, automatic: false, targetWindowID: target.windowID) }
            for _ in 0..<100 where !model.active { try await Task.sleep(for: .milliseconds(1)) }
            await model.cancel()
            var cancelledStart = false
            do { try await starting.value } catch is CancellationError { cancelledStart = true }
            guard cancelledStart, !model.active, !model.processingSegment, model.preview.tiles.isEmpty, completions == 1 else {
                throw CaptureError.message("Cancelled long image restored stale state")
            }
            self.window?.close(); self.window = nil
            return ["pixels": "\(width)x\(height)", "saved": true, "cancelledStart": true]
        }
        await check("large-long-image-worker-responsive") {
            let image = try self.fixture(width: 3840, height: 2160)
            let stitcher = try ScrollStitcher(directory: self.root.appendingPathComponent("scroll-worker"))
            let worker = ScrollCaptureWorker(stitcher)
            let start = ProcessInfo.processInfo.systemUptime
            let update = try await worker.append(image)
            let appendSeconds = ProcessInfo.processInfo.systemUptime - start
            let result = try await worker.render()
            guard update.frames == 1, update.preview.tiles.first?.image.width == 240,
                  result.width == image.width, result.height == image.height else {
                throw CaptureError.message("Large long image worker output differs")
            }
            // Production model uses the same worker for undo and export; the
            // pixel/recapture regression covers multi-segment ordering.
            return ["pixels": "3840x2160", "appendSeconds": appendSeconds, "previewWidth": 240]
        }
        for scenario in [(ScrollDirection.reverse, 900, 1200, "native-upward-scroll-generated-target"),
                         (.reverse, 1800, 0, "native-scroll-reverse-1800ms"),
                         (.forward, 900, 0, "native-scroll-forward-900ms"),
                         (.forward, 1800, 0, "native-scroll-forward-1800ms")] {
        await check(scenario.3) {
            let target = Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("ScrollFixtureTarget.app/Contents/MacOS/ScrollFixtureTarget")
            guard FileManager.default.isExecutableFile(atPath: target.path) else { throw CaptureError.message("Generated scroll target executable missing") }
            let metadata = self.root.appendingPathComponent("scroll-target-\(scenario.3).json")
            let automatic = AXIsProcessTrusted()
            guard automatic else { throw CaptureError.message("Existing AX permission required; automatic delayed-scroll coverage unavailable") }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [metadata.path, "--nested", "--fixed-bars", "--safe-position", "--delay-ms=\(scenario.1)", "--transition-ms=\(scenario.2)"] + (automatic ? [] : ["--timed-steps"])
            let inspectDynamic = CommandLine.arguments.contains("--inspect-dynamic-regions-ui") && scenario.3 == "native-upward-scroll-generated-target"
            if inspectDynamic { configuration.arguments.append("--animate-corner") }
            configuration.createsNewApplicationInstance = true; configuration.activates = true
            if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { configuration.environment = ["CFFIXED_USER_HOME": home] }
            let application = try await NSWorkspace.shared.openApplication(
                at: target.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), configuration: configuration)
            defer { application.terminate() }
            var info: [String: Any]?
            for _ in 0..<100 where info == nil {
                if let data = try? Data(contentsOf: metadata) { info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
                if info == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            guard let info, let components = info["rect"] as? [Double], components.count == 4,
                  let scale = info["scale"] as? Double, let initialY = info["initialY"] as? Double,
                  let viewportHeight = info["viewportHeight"] as? Double else { throw CaptureError.message("Scroll target metadata missing") }
            let world = CGRect(x: components[0], y: components[1], width: components[2], height: components[3])
            let content = try await CaptureEngine().content()
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(world) }) else { throw CaptureError.message("Scroll target outside current screens") }
            guard content.windows.contains(where: { $0.owningApplication?.processID == application.processIdentifier && $0.isOnScreen }) else {
                throw CaptureError.message("Generated target is not in current captured windows")
            }
            let model = ScrollCapture()
            var rendered: CGImage?
            model.onFinish = { image, _ in rendered = image }
            try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                                  content: content, automatic: false, direction: scenario.0)
            let count = model.containers.count
            if automatic {
                guard count >= 2, let selected = model.selectedContainer,
                      selected.frame.width <= components[2] + 2 else {
                    await model.cancel()
                    throw CaptureError.message("Nested scroll areas were not identified: \(count)")
                }
                let initialFrames = model.frames, initialHeight = model.preview.height
                model.setManualScrollPoint(x: 0.6, y: 0.4)
                guard model.paused, model.frames == initialFrames, model.preview.height == initialHeight else {
                    throw CaptureError.message("Manual target correction lost accepted content")
                }
                model.selectContainer(selected.id)
            }
            if inspectDynamic {
                _ = model.setAutomatic(false, requestPermission: false)
                self.present(ScrollHUD(scroll: model, finish: {}, save: {}, cancel: {}))
                for _ in 0..<100 where model.unstableRegions.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
                guard !model.unstableRegions.isEmpty, model.stabilityThumbnail != nil else { await model.cancel(); throw CaptureError.message("No local dynamic region identified") }
                if !model.paused { model.togglePause() }
                let count = model.unstableRegions.count
                try await Task.sleep(for: .seconds(45))
                await model.cancel(); self.window?.close(); self.window = nil
                return ["uiInspectionOnly": true, "dynamicRegions": count, "clipboardTouched": false, "userContentUsed": false]
            }
            if CommandLine.arguments.contains("--inspect-scroll-container-ui"), scenario.3 == "native-upward-scroll-generated-target" {
                if !model.paused { model.togglePause() }
                self.present(ScrollHUD(scroll: model, finish: {}, save: {}, cancel: {}))
                try await Task.sleep(for: .seconds(45))
            }
            if automatic, !model.setAutomatic(true, requestPermission: false) { throw CaptureError.message("Existing automatic scroll permission unavailable") }
            self.present(ScrollHUD(scroll: model, finish: {}, save: {}, cancel: {}))
            // Raising the diagnostic HUD can also raise another window of the
            // same application. Restore the owned generated target before the
            // first wheel; production still pauses on any real obstruction.
            application.activate(options: [])
            try await Task.sleep(for: .milliseconds(200))
            defer {
                self.window?.close(); self.window = nil
                Task { await model.cancel() }
            }
            for _ in 0..<300 where model.frames < 4 {
                if let edges = model.suggestedFixedEdges {
                    guard edges == ScrollFixedEdges(leading: Int(36 * scale), trailing: Int(28 * scale)) else { throw CaptureError.message("Incorrect native fixed edge detection: \(edges); initialFrameSamples=\(model.initialFrameSamples)") }
                    if CommandLine.arguments.contains("--inspect-fixed-bars-ui"), scenario.3 == "native-upward-scroll-generated-target" { try await Task.sleep(for: .seconds(45)) }
                    if model.suggestedFixedEdges != nil { await model.configureFixedEdges(edges) }
                    if automatic { _ = model.setAutomatic(true, requestPermission: false) } else { model.continueManually() }
                } else if model.paused { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard model.frames >= 4 else {
                let selected = model.targetWindowGeometry
                let current = selected.flatMap { CaptureWindowInfo.read($0.id) }
                let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).map {
                    ["id": $0[kCGWindowNumber as String] ?? 0, "pid": $0[kCGWindowOwnerPID as String] ?? 0,
                     "layer": $0[kCGWindowLayer as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]]
                }
                let message = model.warning ?? "Upward capture did not append 4 frames"
                let container = model.selectedContainer
                let selection = model.containerSelection
                await model.cancel()
                throw CaptureError.message("\(message); target=\(String(describing: selected)); current=\(String(describing: current?.frame)); fixturePID=\(application.processIdentifier); container=\(String(describing: container)); selection=\(selection); visibleGeometry=\(visible)")
            }
            let fixedEdgesConfirmed = model.fixedEdges == ScrollFixedEdges(leading: Int(36 * scale), trailing: Int(28 * scale))
            guard fixedEdgesConfirmed else { throw CaptureError.message("Native resolved fixed edges mismatch: \(model.fixedEdges)") }
            if !model.paused { model.togglePause() }
            if automatic, let panel = self.window {
                let preservedFrames = model.frames, preservedHeight = model.preview.height
                let cover = NSButton(title: "DeskCapture 生成遮挡样本", target: nil, action: nil)
                cover.autoresizingMask = [.width, .height]
                panel.contentView = cover
                panel.contentMinSize = .zero; panel.contentMaxSize = CGSize(width: 10_000, height: 10_000)
                panel.setFrame(world, display: true); panel.level = .floating; panel.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(200))
                model.togglePause()
                for _ in 0..<150 where !model.paused { try await Task.sleep(for: .milliseconds(20)) }
                guard model.paused, DiagnosticScrollMessages.matches(model.warning, reason: .obscured),
                      model.frames == preservedFrames, model.preview.height == preservedHeight else {
                    throw CaptureError.message("Owned obstruction did not pause and preserve capture: paused=\(model.paused), warning=\(model.warning ?? "none"), frames=\(model.frames)/\(preservedFrames), height=\(model.preview.height)/\(preservedHeight), panel=\(panel.frame)")
                }
                panel.level = .normal; panel.close()
            }
            let frames = model.frames, height = model.preview.height
            let expectedStep = Int((Double(ScrollCaptureSpeed.standard.step(for: CGFloat(viewportHeight) - 8)) * scale).rounded())
            guard height == Int((components[3] * scale).rounded()) + (frames - 1) * expectedStep else {
                throw CaptureError.message("Intermediate transition was committed as a full capture: height=\(height), step=\(expectedStep)")
            }
            let destination = self.root.appendingPathComponent("scroll-\(scenario.3).png")
            await model.finish(output: .file(destination))
            guard let rendered, !model.active, rendered.height == height else { throw CaptureError.message("Upward native export failed") }
            let sourceWidth = Int((components[2] * scale).rounded()), sourceHeight = Int((2500 * scale).rounded())
            let bottom = Int(((initialY + viewportHeight) * scale).rounded())
            let expected = try await Task.detached { () throws -> CGImage in
                let page = WorkflowCorpus.texture(width: sourceWidth, height: sourceHeight, seed: 42)
                let leading = Int(36 * scale), trailing = Int(28 * scale), bodyHeight = height - leading - trailing
                guard let crop = page.cropping(to: CGRect(x: 0, y: scenario.0 == .reverse ? bottom - bodyHeight : Int((initialY * scale).rounded()), width: sourceWidth, height: bodyHeight)),
                      let context = CGContext(data: nil, width: sourceWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("Expected native scroll crop unavailable") }
                context.draw(WorkflowCorpus.texture(width: sourceWidth, height: leading, seed: 777), in: CGRect(x: 0, y: height - leading, width: sourceWidth, height: leading))
                context.draw(crop, in: CGRect(x: 0, y: trailing, width: sourceWidth, height: bodyHeight))
                context.draw(WorkflowCorpus.texture(width: sourceWidth, height: trailing, seed: 778), in: CGRect(x: 0, y: 0, width: sourceWidth, height: trailing))
                return context.makeImage()!
            }.value
            let error = await Task.detached { () -> Double in
                let a = ScrollMatcher.grayscale(rendered), b = ScrollMatcher.grayscale(expected)
                guard a.count == b.count, !a.isEmpty else { return 255 }
                return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
            }.value
            guard error <= 2 else { throw CaptureError.message("Native upward pixel order mismatch: mean error \(error)") }
            let finalInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
            guard let outerBefore = info["outerY"] as? Double, let outerAfter = finalInfo?["outerY"] as? Double,
                  outerBefore == outerAfter else { throw CaptureError.message("Automatic scroll moved the outer container") }
            guard finalInfo?["maxPendingScrolls"] as? Int == 1 else { throw CaptureError.message("Delayed scroll wheels overlapped") }
            // Let any last acknowledged request finish, then cancel a new
            // outstanding wheel before its deliberately delayed redraw.
            for _ in 0..<100 {
                let data = try Data(contentsOf: metadata)
                let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if state?["pendingScrolls"] as? Int == 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            self.window?.close(); self.window = nil
            application.activate(options: [])
            try await Task.sleep(for: .milliseconds(300))
            let cancellation = ScrollCapture()
            var cancellationCompletions = 0
            cancellation.onFinish = { _, _ in cancellationCompletions += 1 }
            try await cancellation.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                                         content: content, automatic: false, direction: .reverse)
            if automatic {
                guard cancellation.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Cannot start cancellation probe") }
                var queued = false
                for _ in 0..<100 where !queued {
                    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
                    queued = (state?["pendingScrolls"] as? Int ?? 0) > 0
                    if !queued { try await Task.sleep(for: .milliseconds(20)) }
                }
                guard queued else { throw CaptureError.message("No delayed request queued before cancellation: paused=\(cancellation.paused), warning=\(cancellation.warning ?? "none"), target=\(String(describing: cancellation.targetWindowGeometry)), containers=\(cancellation.containers.count)") }
            }
            let beforeCancel = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
            await cancellation.cancel()
            try await Task.sleep(for: .milliseconds(2500))
            let afterCancel = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
            guard let beforeY = beforeCancel?["currentY"] as? Double, let afterY = afterCancel?["currentY"] as? Double,
                  afterY < beforeY else { throw CaptureError.message("Delayed redraw did not actually occur after cancellation") }
            guard !cancellation.active, !cancellation.scanningContainers, cancellation.containers.isEmpty,
                  cancellation.preview.tiles.isEmpty, cancellation.stabilityThumbnail == nil,
                  !cancellation.waitingForStableFrame, cancellationCompletions == 0 else { throw CaptureError.message("Cancelled delayed frame restored stale state") }
            self.window?.close(); self.window = nil
            return ["frames": frames, "pixels": "\(rendered.width)x\(rendered.height)", "meanGrayError": error,
                    "automaticWheelVerified": automatic, "mode": automatic ? "production-wheel" : "timed-fixture-manual-capture",
                    "containerCount": count, "outerContainerUnchanged": true, "manualCorrectionPreservedContent": automatic,
                    "delayedFrameCancellation": true,
                    "fixedEdgesConfirmed": fixedEdgesConfirmed, "fixedEdgesOnlyOnce": true, "initialFrameSamples": model.initialFrameSamples,
                    "ownedObstructionPaused": automatic,
                    "delayedWheelMaxPending": finalInfo?["maxPendingScrolls"] ?? -1,
                    "clipboardTouched": false, "userContentUsed": false]
        }
        }
        await check("native-scroll-top-boundary") {
            guard AXIsProcessTrusted() else { throw CaptureError.message("Existing AX permission required for boundary wheel verification") }
            let fixture = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ScrollFixtureTarget.app")
            let metadata = self.root.appendingPathComponent("top-boundary.json")
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = [metadata.path, "--initial-y=0", "--delay-ms=900", "--safe-position"]
            config.createsNewApplicationInstance = true; config.activates = true
            if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { config.environment = ["CFFIXED_USER_HOME": home] }
            let application = try await NSWorkspace.shared.openApplication(at: fixture, configuration: config)
            defer { application.terminate() }
            var info: [String: Any]?
            for _ in 0..<100 where info == nil {
                if let data = try? Data(contentsOf: metadata) { info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
                if info == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            guard let info, let coordinates = info["rect"] as? [Double], coordinates.count == 4 else { throw CaptureError.message("Boundary fixture metadata missing") }
            let world = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(world) }) else { throw CaptureError.message("Boundary outside screen") }
            application.activate(options: [])
            try await Task.sleep(for: .milliseconds(300))
            let model = ScrollCapture()
            try await model.start(screen: screen, rect: world.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                                  content: CaptureEngine().content(), automatic: false, direction: .reverse)
            guard model.setAutomatic(true, requestPermission: false) else { throw CaptureError.message("Boundary automatic scroll unavailable") }
            for _ in 0..<150 where !model.paused { try await Task.sleep(for: .milliseconds(100)) }
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any]
            guard model.paused, model.frames == 1, model.stopReason != nil,
                  state?["receivedScrollEvents"] as? Int == 1, state?["maxPendingScrolls"] as? Int == 1,
                  state?["currentY"] as? Double == 0 else { await model.cancel(); throw CaptureError.message("Top boundary failed: paused=\(model.paused), frames=\(model.frames), warning=\(model.warning ?? "none"), state=\(String(describing: state))") }
            let boundaryConfirmed = model.stopReason == .boundary
            let destination = self.root.appendingPathComponent("top-boundary.png")
            await model.finish(output: .file(destination))
            guard !model.active, FileManager.default.fileExists(atPath: destination.path) else { throw CaptureError.message("Boundary image export failed") }
            let scale = screen.backingScaleFactor
            let error = try await Task.detached { () throws -> Double in
                let image = try CaptureImageRead.load(destination)
                let page = WorkflowCorpus.texture(width: Int(world.width * scale), height: Int(2500 * scale), seed: 42)
                guard let expected = page.cropping(to: CGRect(x: 0, y: 0, width: Int(world.width * scale), height: Int(world.height * scale))),
                      image.width == expected.width, image.height == expected.height else { throw CaptureError.message("Boundary output dimensions changed") }
                let a = ScrollMatcher.grayscale(image), b = ScrollMatcher.grayscale(expected)
                return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
            }.value
            guard error <= 2 else { throw CaptureError.message("Boundary pixels differ: \(error)") }
            return ["requests": 1, "frames": 1, "pausedAtBoundary": boundaryConfirmed, "boundaryConfirmed": boundaryConfirmed, "singleOutstandingVerified": true, "meanGrayError": error]
        }
        if CommandLine.arguments.contains("--native-document-probe") {
            await check("native-document-geometry") {
                if ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_CASE"]?.hasPrefix("P") == true { return try await PreviewDocumentProbe.run() }
                return try await NativeDocumentProbe.run()
            }
        }
        if CommandLine.arguments.contains("--native-scroll-diagnostic") {
            await check("real-native-scroll-fixture") {
                if ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_CASE"]?.hasPrefix("P") == true { return try await PreviewScrollDiagnostic.run(root: self.root) }
                return try await NativeScrollDiagnostic.run(root: self.root)
            }
        }
        if CommandLine.arguments.contains("--browser-scroll-diagnostic") {
            await check("real-browser-scroll-fixture") { try await BrowserScrollDiagnostic.run(root: self.root) }
        }
        await check("streamed-long-beyond-old-limits") {
            try await ScrollStreamDiagnostic.run(root: self.root, inspect: CommandLine.arguments.contains("--inspect-stream-export-ui")) { model in
                self.present(ScrollHUD(scroll: model, finish: {}, save: { ScrollFileDialog.present(for: model) }, cancel: { Task { await model.cancel() } }))
            }
        }
        await check("camera-repeated-stop-preview-teardown") {
            let recorder = DeviceRecorder(); self.phase = "device discovery"; await recorder.refresh()
            guard let device = recorder.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { throw CaptureError.message("No built-in camera") }
            recorder.selectedID = device.uniqueID
            recorder.selectedAudioID = "no-audio" // This check covers camera lifecycle, not audio capture.
            self.phase = "create camera preview"; self.present(DeviceRecordingView(recorder: recorder))
            var saved: URL?, times: [Double] = []
            recorder.onFinish = { saved = $0 }
            for index in 0..<10 {
                saved = nil; self.phase = "camera start \(index)"; await recorder.start(diagnostic: true)
                guard recorder.state == .recording else { throw CaptureError.message(recorder.message ?? "Camera start failed") }
                self.phase = "camera recording \(index)"
                try await Task.sleep(for: .seconds(index == 0 ? 55 : 1))
                if index == 1 {
                    await recorder.togglePause(); guard recorder.state == .paused else { throw CaptureError.message("Camera pause failed") }
                    await recorder.togglePause(); try await Task.sleep(for: .seconds(1))
                }
                self.phase = "camera stop \(index)"
                let start = ProcessInfo.processInfo.systemUptime; await recorder.stop(); times.append(ProcessInfo.processInfo.systemUptime - start)
                guard let saved, recorder.state == .idle else { throw CaptureError.message(recorder.message ?? "Camera stop failed") }
                self.phase = "camera file validation \(index)"
                let info = try await self.validateMovie(saved)
                guard (info["duration"] as? Double ?? 0) >= (index == 0 ? 50 : 0.8) else { throw CaptureError.message("Camera recording ended early") }
                try await Task.sleep(for: .milliseconds(200))
            }
            self.window?.close(); self.window = nil
            return ["cycles": 10, "stopSeconds": times]
        }
        await check("device-window-close-saves-active-recording") {
            let recorder = DeviceRecorder(); await recorder.refresh()
            guard let device = recorder.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { throw CaptureError.message("No built-in camera") }
            recorder.selectedID = device.uniqueID
            recorder.selectedAudioID = "no-audio" // Keep this lifecycle fixture explicitly video-only.
            let window = DeviceRecordingWindow(recorder: recorder)
            self.window = window; window.orderFrontRegardless()
            var saved: URL?
            recorder.onFinish = { saved = $0 }
            await recorder.start(diagnostic: true)
            guard recorder.state == .recording else { throw CaptureError.message(recorder.message ?? "Camera start failed") }
            try await Task.sleep(for: .seconds(1))
            window.performClose(nil)
            for _ in 0..<200 where saved == nil || window.isVisible { try await Task.sleep(for: .milliseconds(10)) }
            guard let saved, recorder.state == .idle, !window.isVisible else { throw CaptureError.message(recorder.message ?? "Close did not finish and save recording") }
            let info = try await self.validateMovie(saved)
            window.makeKeyAndOrderFront(nil)
            guard window.isVisible else { throw CaptureError.message("Window could not reopen") }
            window.performClose(nil)
            guard !window.isVisible else { throw CaptureError.message("Idle window did not close") }
            self.window = nil
            return ["movie": info, "savedBeforeClose": true, "reopenedAndClosed": true]
        }
        await check("screen-camera-30fps-pause-resume-export-cancel") {
            let recorder = ScreenRecorder(preferences: self.preferences)
            recorder.cameraEnabled = true; recorder.fps = 30
            let cameraIdentity = try await DiagnosticCamera.resolve()
            recorder.cameraDeviceID = cameraIdentity.id
            let owned = try await self.prepareCaptureFixture()
            let content = try await CaptureEngine().content()
            let screen = try self.availableScreen(in: content)
            guard let source=content.windows.filter({$0.owningApplication?.processID==owned.processIdentifier && $0.isOnScreen})
                .max(by:{$0.frame.width*$0.frame.height<$1.frame.width*$1.frame.height}) else { throw CaptureError.message("生成的屏幕录制夹具缺失。") }
            var saved: URL?, failure: Error?
            recorder.onFinish = { saved = $0 }; recorder.onError = { failure = $0 }
            self.present(RecordingHUD(recorder: recorder, stop: {}))
            try await recorder.start(screen: screen, rect: CGRect(x: 20, y: 100, width: 960, height: 540), content: content, diagnostic: true, diagnosticSource:source)
            try await Task.sleep(for: .seconds(55))
            await recorder.togglePause(); guard recorder.state == .paused else { throw failure ?? CaptureError.message("Screen pause failed") }
            try await Task.sleep(for: .milliseconds(500)); await recorder.togglePause()
            guard recorder.state == .recording else { throw failure ?? CaptureError.message("Screen resume failed") }
            try await Task.sleep(for: .seconds(3))
            let start = ProcessInfo.processInfo.systemUptime; await recorder.stop()
            let stop = ProcessInfo.processInfo.systemUptime - start
            guard let saved else { throw failure ?? CaptureError.message("Screen save failed") }
            let movie = try await self.validateMovie(saved)
            let cadence = try await RecordedFrameCadence.measure(saved)
            guard recorder.recordedWithCamera, try await RecordingCameraMaterial.inspect(for: saved) == .ready else { throw CaptureError.message("Camera recording was requested but its saved material is not readable") }
            let cameraAsset = AVURLAsset(url: RecordingCamera.url(for: saved))
            defer { withExtendedLifetime(cameraAsset) {} }
            let cameraSeconds = try await cameraAsset.load(.duration).seconds
            guard recorder.cameraStopEvent == nil, cameraSeconds >= (movie["duration"] as? Double ?? 0) - 1 else {
                throw CaptureError.message("Camera coverage interrupted: \(cameraSeconds)s; \(recorder.cameraStopEvent?.message ?? "no system reason supplied")")
            }
            let trim = self.root.appendingPathComponent("trim.mp4")
            try await VideoTrimmer.export(saved, to: trim, start: 0.2, end: 1.2)
            let trimmed = try await self.validateMovie(trim)
            var options = RecordingEffectsOptions(); options.maximumDimension = 960; options.outputFPS = 15
            options.camera.shape = .cutout; options.audio.cleanup = true; options.audio.normalize = true
            options.audio.spectralReduction = true
            options.captions = [CaptionSegment(start: 0, end: 3, text: "质量验证 DeskCapture")]
            let effect = self.root.appendingPathComponent("effect.mp4")
            try await RecordingEffectsExporter.export(saved, to: effect, options: options, end: 3)
            _ = try await self.validateMovie(effect)
            let gif = self.root.appendingPathComponent("preview.gif")
            try await VideoGIFExporter.export(trim, to: gif)
            guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(source) > 1 else { throw CaptureError.message("GIF missing frames") }
            let destination = self.root.appendingPathComponent("cancel.mp4"), sentinel = Data("keep existing file".utf8)
            try sentinel.write(to: destination)
            let task = Task { try await RecordingEffectsExporter.export(saved, to: destination, options: options) }
            try await Task.sleep(for: .milliseconds(150)); task.cancel()
            do { try await task.value; throw CaptureError.message("Cancelled export unexpectedly succeeded") } catch is CancellationError {} catch { if !task.isCancelled { throw error } }
            guard try Data(contentsOf: destination) == sentinel else { throw CaptureError.message("Cancel damaged destination") }
            self.window?.close(); self.window = nil
            return ["movie": movie, "trim": trimmed, "stopSeconds": stop, "exportCancelPreservedFile": true, "cameraMaterialReadable": true, "fps": 30, "cadence": cadence.report,
                    "captureSamples": recorder.captureStatistics.report,
                    "cameraDevice": cameraIdentity.report, "cameraDurationSeconds": cameraSeconds,
                    "sourceMotionScope": "generated screen and live camera; static VFR holds are not a steady-motion benchmark"]
        }
        if CommandLine.arguments.contains("--long-recording-diagnostic") {
            await check("long-recording-resources") {
                let fixture = try await self.prepareCaptureFixture()
                let content = try await CaptureEngine().content()
                guard let target = content.windows.filter({ $0.owningApplication?.processID == fixture.processIdentifier && $0.isOnScreen })
                    .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { throw CaptureError.message("长时诊断的生成窗口缺失。") }
                return try await LongRecordingDiagnostic.run(root: self.root, preferences: self.preferences, sourceWindow: target) { self.phase = $0 }
            }
        }
        do {
            guard let executable = Bundle.main.executableURL else { throw CaptureError.message("当前诊断文件失效。") }
            let after = try await Task.detached(priority: .utility) { try ArtifactIdentity.sha256(executable) }.value
            guard after == executableSHA256 else { throw CaptureError.message("诊断期间可执行文件已改变，本次不能用于交付。") }
        } catch { rows.append(["case": "candidate-identity", "success": false, "error": error.localizedDescription]) }
        if let fixture = captureFixture {
            fixture.terminate()
            for _ in 0..<20 where !fixture.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
            if !fixture.isTerminated { fixture.forceTerminate() }
            captureFixture = nil
        }
        writeReport(finished: true)
        NSApp.terminate(nil)
    }
    private func prepareCaptureFixture() async throws -> NSRunningApplication {
        if let captureFixture, !captureFixture.isTerminated { return captureFixture }
        let fixture = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ScrollFixtureTarget.app")
        let metadata = root.appendingPathComponent("capture-fixture.json")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [metadata.path, "--capture-backdrop", "--backdrop-only", "--owner-pid=\(ProcessInfo.processInfo.processIdentifier)"]
        config.createsNewApplicationInstance = true; config.activates = true
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { config.environment = ["CFFIXED_USER_HOME": home] }
        let owned = try await NSWorkspace.shared.openApplication(at: fixture, configuration: config)
        captureFixture = owned
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: metadata.path) { try await Task.sleep(for: .milliseconds(50)) }
        guard FileManager.default.fileExists(atPath: metadata.path) else { throw CaptureError.message("Owned generated capture fixture was not ready") }
        return owned
    }
    private func availableScreen(in content: SCShareableContent) throws -> NSScreen {
        // Resolve the current AppKit screen after the asynchronous SCK query.
        // Diagnostics select a screen themselves; never reuse a stale main-screen
        // object held across device/window changes or a display reconfiguration.
        let ids = content.displays.map(\.displayID)
        if let screen = NSScreen.screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            return ids.contains(id)
        }) { return screen }
        let appKitIDs = NSScreen.screens.map { String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]) }
        throw CaptureError.message("No matching display: AppKit=\(appKitIDs), ScreenCaptureKit=\(ids)")
    }
    private func present<V: View>(_ view: V) {
        window?.close()
        let panel = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 460, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "DeskCapture 质量测试（自动进行）"
        let inspect = CommandLine.arguments.contains("--inspect-scroll-container-ui") || CommandLine.arguments.contains("--inspect-fixed-bars-ui") || CommandLine.arguments.contains("--inspect-dynamic-regions-ui") || CommandLine.arguments.contains("--inspect-stream-export-ui")
        panel.isReleasedWhenClosed = false; panel.contentView = NSHostingView(rootView: view.disabled(!inspect).allowsHitTesting(inspect)); panel.orderFrontRegardless(); window = panel
    }
    private func validateMovie(_ url: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: url), duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0.2, let track = tracks.first else { throw CaptureError.message("Invalid movie") }
        let generator = AVAssetImageGenerator(asset: asset)
        _ = try await generator.image(at: CMTime(seconds: min(0.2, duration / 2), preferredTimescale: 600))
        return ["duration": duration, "fps": try await track.load(.nominalFrameRate), "audioTracks": try await asset.loadTracks(withMediaType: .audio).count]
    }
    private func fixture(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("Fixture allocation failed") }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("DeskCapture Quality Test 2026" as NSString).draw(at: CGPoint(x: 50, y: CGFloat(height) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        return context.makeImage()!
    }
    static func cleanupFixture() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message("Fixture allocation failed") }
        context.setFillColor(NSColor(srgbRed: 0.94, green: 0.95, blue: 0.9, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        context.saveGState()
        context.addEllipse(in: CGRect(x: 260, y: 130, width: 280, height: 290)); context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [NSColor(srgbRed: 1, green: 0.74, blue: 0.1, alpha: 1).cgColor,
                                           NSColor(srgbRed: 0.8, green: 0.23, blue: 0.02, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: CGPoint(x: 350, y: 340), startRadius: 0,
                                   endCenter: CGPoint(x: 400, y: 275), endRadius: 190, options: [.drawsAfterEndLocation])
        context.restoreGState()
        context.setFillColor(NSColor(srgbRed: 0.13, green: 0.46, blue: 0.12, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 400, y: 400, width: 100, height: 36))
        guard let image = context.makeImage() else { throw CaptureError.message("Fixture allocation failed") }
        return image
    }
    static func alpha(_ image: CGImage, at point: CGPoint) -> Int {
        guard let pixel = image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(context.data!.assumingMemoryBound(to: UInt8.self)[3])
    }
}
