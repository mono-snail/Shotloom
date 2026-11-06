import AppKit
import ApplicationServices
import ScreenCaptureKit

enum ScrollCaptureSource: Equatable {
    case region, window
    var captureMode: CaptureMode { self == .window ? .scrollingWindow : .scrolling }
}

enum ScrollWindowGeometry {
    static func localRect(_ frame: CGRect, screenFrame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX - screenFrame.minX, y: desktopTop - frame.maxY - screenFrame.minY,
               width: frame.width, height: frame.height)
    }
    static func sizeMatches(_ expected: CGRect, _ current: CGRect) -> Bool {
        abs(expected.width - current.width) <= 1 && abs(expected.height - current.height) <= 1
    }
    /// App activation alone can raise a different document belonging to the
    /// same application. Raise only the AX window matching our selected frame.
    /// Called off the UI actor, with bounded IPC and no content reads.
    static func raise(pid: pid_t, frame: CGRect) {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        var matches: [AXUIElement] = []
        for window in windows.prefix(64) {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return }
            AXUIElementSetMessagingTimeout(window, 0.12)
            var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let rawPosition, let rawSize, CFGetTypeID(rawPosition) == AXValueGetTypeID(),
                  CFGetTypeID(rawSize) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point), AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
                  abs(point.x - frame.minX) <= 1, abs(point.y - frame.minY) <= 1,
                  sizeMatches(frame, CGRect(origin: point, size: size)) else { continue }
            matches.append(window)
            if matches.count > 1 { return }
        }
        guard !Task.isCancelled, matches.count == 1 else { return }
        AXUIElementPerformAction(matches[0], kAXRaiseAction as CFString)
    }
}

extension CaptureEngine {
    /// Desktop-independent window pixels, without user screenshot backdrops or
    /// shadows. Region capture continues through its existing acquisition path.
    func scrollingWindow(_ window: SCWindow, validate: @MainActor () throws -> Void = {}) async throws -> CGImage {
        try Task.checkCancellation(); try validate()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              size.width * size.height * scale * scale <= 80_000_000,
              max(size.width, size.height) * scale <= 60_000 else { throw CaptureError.message(L10n.text("这个窗口太大，无法开始长图。请缩小窗口后重试。")) }
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int((size.width * scale).rounded()))
        configuration.height = max(2, Int((size.height * scale).rounded()))
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = false; configuration.captureResolution = .best
        let clear = CGColor(gray: 0, alpha: 0)
        configuration.backgroundColor = clear
        defer { withExtendedLifetime(clear) {} }
        let image = try await captureWithTimeout {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
        try Task.checkCancellation(); try validate()
        return image
    }
}
