import AppKit
import ScreenCaptureKit
import Vision

struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
    var desktopFrame: CGRect? = nil
    var capturedFrame: CGRect? = nil
    var topology: DesktopTopology? = nil
    var frame: CGRect { desktopFrame ?? capturedFrame ?? screen.frame }
    var scale: CGFloat { CGFloat(image.width) / frame.width }
}

struct OCRLine: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let bounds: CGRect
    let confidence: Float
    var alternatives: [String] = []
    // Vision confidence is a review hint, not a probability of correctness.
    var needsReview: Bool { !confidence.isFinite || confidence < 0.8 || !alternatives.isEmpty }
}

@MainActor
final class CaptureEngine {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func normalizedCaptureError(_ error: Error) -> Error {
        var current = error as NSError
        for _ in 0..<5 {
            if current.domain == SCStreamErrorDomain && current.code == SCStreamError.Code.userDeclined.rawValue {
                return CaptureError.permission
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return error
    }

    /// A shareable-content list alone does not prove screenshot access. Exercise
    /// the same API/filter as capture with a tiny region, kept only in memory.
    func confirmScreenshotAccess() async throws {
        let content = try await content()
        guard let display = content.displays.first else {
            throw CaptureError.message(L10n.text("没有找到可捕获的屏幕，请检查显示器连接后重试。"))
        }
        let filter = displayFilter(display, content: content)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: 0, y: 0, width: 2, height: 2)
        configuration.width = 2; configuration.height = 2
        configuration.showsCursor = false
        configuration.captureResolution = .best
        _ = try await captureWithTimeout {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        try Task.checkCancellation()
    }

    func content() async throws -> SCShareableContent {
        // CoreGraphics preflight is advisory. ScreenCaptureKit is the authority for
        // this capture path, especially after signing changes and on new macOS.
        do {
            let visible = try await captureWithTimeout { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            if !visible.displays.isEmpty { return visible }
            // Some WindowServer transitions return no displays for the visible-only
            // query even though AppKit still has an active screen. Refresh the full
            // inventory; callers still match an AppKit display and visible windows.
            return try await captureWithTimeout { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        } catch {
            throw Self.normalizedCaptureError(error)
        }
    }

    private func displayFilter(_ display: SCDisplay, content: SCShareableContent, preferences: CapturePreferences = .init()) -> SCContentFilter {
        let apps = content.applications.filter { $0.processID != ProcessInfo.processInfo.processIdentifier }
        if preferences.hideDesktop {
            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            filter.includeMenuBar = true
            return filter
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }
    func region(_ rect: CGRect, screen: NSScreen, content: SCShareableContent) async throws -> CGImage {
        let topology = DesktopTopology.current(), geometry = try topology.display(for: screen)
        guard let display = content.displays.first(where: { $0.displayID == geometry.id }) else {
            throw CaptureError.message(L10n.text("显示器已断开，请重新选择区域。"))
        }
        // A menu-only app may have no entry in the caller's initial inventory.
        // Refresh when needed so a subsequently opened capture HUD is excluded.
        let filterContent: SCShareableContent
        if content.applications.contains(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) {
            filterContent = content
        } else {
            filterContent = try await self.content()
        }
        let filter = displayFilter(display, content: filterContent)
        let config = SCStreamConfiguration()
        config.sourceRect = try geometry.sourceRect(rect)
        config.width = max(2, Int(rect.width * geometry.scale))
        config.height = max(2, Int(rect.height * geometry.scale))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await captureWithTimeout { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        try topology.requireUnchanged(); try Task.checkCancellation(); return image
    }

    func visibleRegion(_ rect: CGRect, screen: NSScreen, content: SCShareableContent, target: SCWindow,
                       validate: @MainActor () throws -> Void = {}) async throws -> CGImage {
        let topology=DesktopTopology.current(), geometry=try topology.display(for:screen)
        guard let display=content.displays.first(where: { $0.displayID==geometry.id }) else { throw CaptureError.message(L10n.text("显示器已断开，请重新选择区域。")) }
        let referenceFilter=SCContentFilter(display:display,including:[target])
        referenceFilter.includeMenuBar=false
        let referenceConfig=SCStreamConfiguration()
        let raster = ScrollFrameRaster(source: try geometry.sourceRect(rect), scale: geometry.scale)
        referenceConfig.sourceRect=raster.source
        referenceConfig.width=raster.width;referenceConfig.height=raster.height
        referenceConfig.showsCursor=false;referenceConfig.captureResolution = .best
        referenceConfig.shouldBeOpaque=false
        let clear=CGColor(gray:0,alpha:0);referenceConfig.backgroundColor=clear
        defer { withExtendedLifetime(clear) {} }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let regionWorld = CGRect(x: screen.frame.minX + rect.minX,
                                 y: top - screen.frame.minY - rect.maxY,
                                 width: rect.width, height: rect.height)
        let displayWorld = CGRect(x: screen.frame.minX, y: top - screen.frame.maxY,
                                  width: screen.frame.width, height: screen.frame.height)
        func requireUncovered() throws {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            if let reason = ScrollWindowVisibility.failure(region: regionWorld, target: target.windowID,
                ownPID: ProcessInfo.processInfo.processIdentifier, display: displayWorld, windows: windows,
                bundlePath: { NSRunningApplication(processIdentifier: $0)?.bundleURL?.path }) {
                throw ScrollVisibleFrame.Occluded(reason: reason)
            }
        }
        let diagnosticFolder = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"]
        return try await ScrollVisibleFrame.acquire(transparentBorder: min(64, Int(16 * geometry.scale)), onRejected: { reason in
            guard let diagnosticFolder else { return }
            let inventory = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let overlapping: [[String: Any]] = inventory.compactMap { item in
                guard let raw = item[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                      bounds.intersects(regionWorld) else { return nil }
                let pid = item[kCGWindowOwnerPID as String] as? Int32 ?? 0
                return ["id": item[kCGWindowNumber as String] ?? 0, "pid": pid,
                        "bundle": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "system",
                        "layer": item[kCGWindowLayer as String] ?? 0,
                        "frame": [bounds.minX, bounds.minY, bounds.width, bounds.height]]
            }
            let value: [String: Any] = ["reason": reason, "target": target.windowID,
                "targetFrame": [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height],
                "region": [regionWorld.minX, regionWorld.minY, regionWorld.width, regionWorld.height],
                "windows": overlapping]
            let file = URL(fileURLWithPath: diagnosticFolder).appendingPathComponent("visibility-rejection-\(UUID()).json")
            Task.detached(priority: .utility) {
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                    try? data.write(to: file, options: .atomic)
                }
            }
        }) {
            try topology.requireUnchanged(); try Task.checkCancellation(); try validate()
            try requireUncovered()
            let captured = try await captureWithTimeout {
                try await SCScreenshotManager.captureImage(contentFilter: referenceFilter, configuration: referenceConfig)
            }
            guard let image = captured.cropping(to: raster.crop) else {
                throw CaptureError.message(L10n.text("无法裁剪长图选区，请重新选择区域。"))
            }
            try topology.requireUnchanged(); try Task.checkCancellation(); try validate()
            try requireUncovered()
            // Returning target-only pixels prevents an occlusion race from ever
            // importing another application's pixels. The acquisition boundary
            // preserves rounded transparent edges, then stability checks compare
            // successive target frames instead of two unrelated capture times.
            return (display: image, target: image)
        }
    }

    func snapshots(content: SCShareableContent, preferences: CapturePreferences = .init(), displayID: UInt32? = nil) async throws -> [ScreenSnapshot] {
        let topology = DesktopTopology.current()
        var result: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            if let displayID, id != displayID { continue }
            let geometry = try topology.display(for: screen)
            let filter = displayFilter(display, content: content, preferences: preferences)
            let config = SCStreamConfiguration()
            config.width = Int(geometry.frame.width * geometry.scale)
            config.height = Int(geometry.frame.height * geometry.scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await captureWithTimeout { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
            try topology.requireUnchanged(); try Task.checkCancellation()
            result.append(ScreenSnapshot(screen: screen, image: image, capturedFrame: geometry.frame, topology: topology))
        }
        guard !result.isEmpty else { throw CaptureError.message(L10n.text("没有找到可捕获的显示器，请重新连接显示器后重试。")) }
        return result
    }

    func capture(window: SCWindow, preferences: CapturePreferences = .init()) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let transparentBackground = CGColor(gray: 0, alpha: 0)
        config.backgroundColor = transparentBackground
        // ScreenCaptureKit declares backgroundColor as assign, so retain the
        // color through the asynchronous configuration copy.
        defer { withExtendedLifetime(transparentBackground) {} }
        config.captureResolution = .best
        let image = try await captureWithTimeout { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        return CapturePreferences.windowImage(image, backdrop: preferences.windowBackdrop, shadow: preferences.windowShadow, scale: scale) ?? image
    }

    nonisolated static func recognize(_ image: CGImage) async throws -> String {
        try await recognizeLines(image).map(\.text).joined(separator: "\n")
    }

    nonisolated static func recognizeLines(_ image: CGImage) async throws -> [OCRLine] {
        try await OCRRecognitionWorker.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            let automatic = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }.compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: candidate.string, bounds: observation.boundingBox, confidence: candidate.confidence)
            }
            let explicitRequest = VNRecognizeTextRequest()
            explicitRequest.recognitionLevel = .accurate; explicitRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            explicitRequest.usesLanguageCorrection = true; explicitRequest.automaticallyDetectsLanguage = false
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([explicitRequest])
            try Task.checkCancellation()
            let explicit = (explicitRequest.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: candidate.string, bounds: observation.boundingBox, confidence: candidate.confidence)
            }
            return OCRLanguageReview.merge(automatic: automatic, explicit: explicit)
        }
    }

    nonisolated static func extract(_ image: CGImage, destination: CaptureDestination) async throws -> String {
        if destination == .table {
            if #available(macOS 26.0, *) {
                let table = try await extractTable(image)
                guard !table.requiresReview else { throw CaptureError.message(L10n.text("检测到合并单元格或未归入表格的文字，需要在可见表格窗口复核后交付。")) }
                return table.tsv
            }
            throw CaptureError.message(L10n.text("表格结构提取需要 macOS 26 或更高版本；当前系统可使用普通文字识别。"))
        }
        if destination == .qr {
            return try await OCRRecognitionWorker.run {
                let request = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: image).perform([request])
                let values = (request.results ?? []).compactMap(\.payloadStringValue)
                guard !values.isEmpty else { throw CaptureError.message(L10n.text("没有识别到二维码或条码。")) }
                return values.joined(separator: "\n")
            }
        }
        if destination == .code {
            return try await OCRRecognitionWorker.run {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US", "zh-Hans"]; request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: image).perform([request])
                try Task.checkCancellation()
                return OCRCodeLayout.format(try OCRCodeGlyphs.recover(request.results ?? [], image: image))
            }
        }
        return try await recognize(image)
    }
}
