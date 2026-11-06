import AppKit
import ApplicationServices

@MainActor
enum NativeDocumentProbe {
    static func run() async throws -> [String: Any] {
        guard let folder = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_FIXTURE_DIR"],
              let id = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_CASE"], id.hasPrefix("T"),
              id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw CaptureError.message("Explicit native fixture required") }
        let source = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("DeskCapture-Fixture-\(id).rtfd")
        let content = try await CaptureEngine().content()
        let matches = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.TextEdit" && ($0.title?.contains("DeskCapture-Fixture-\(id)") ?? false) }
        guard matches.count == 1, let window = matches.first, let owner = window.owningApplication else { throw CaptureError.message("Exactly one owned TextEdit document required") }
        return try await Task.detached { try inspect(pid: owner.processID, id: id, source: source) }.value
    }
    nonisolated static func inspect(pid: pid_t, id: String, source: URL, offsets: [Int]? = nil) throws -> [String: Any] {
        func value(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
            var result: CFTypeRef?; return AXUIElementCopyAttributeValue(element, key, &result) == .success ? result : nil
        }
        func rect(_ element: AXUIElement) -> [Double]? {
            guard let p = value(element, kAXPositionAttribute as CFString), let s = value(element, kAXSizeAttribute as CFString),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return [Double(point.x), Double(point.y), Double(size.width), Double(size.height)]
        }
        let expected = try NSAttributedString(url: source, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil).string
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.12)
        guard let windows = value(app, kAXWindowsAttribute as CFString) as? [AXUIElement],
              let window = windows.first(where: { (value($0, kAXTitleAttribute as CFString) as? String)?.contains("DeskCapture-Fixture-\(id)") == true }) else { throw CaptureError.message("Owned TextEdit AX window missing") }
        var queue = [window], areas: [[String: Any]] = [], count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !queue.isEmpty, count < 1000, ProcessInfo.processInfo.systemUptime < deadline {
            let element = queue.removeFirst(); count += 1; AXUIElementSetMessagingTimeout(element, 0.12)
            let role = value(element, kAXRoleAttribute as CFString) as? String ?? ""
            if [kAXScrollAreaRole, kAXTextAreaRole, kAXScrollBarRole, kAXRulerRole].contains(role) {
                var row: [String: Any] = ["role": role, "bounds": rect(element) ?? []]
                if role == kAXTextAreaRole {
                    let text = value(element, kAXValueAttribute as CFString) as? String
                    row["textMatchesOwnedInput"] = text == expected; row["utf16Length"] = text.map { ($0 as NSString).length } ?? -1
                    if let raw = value(element, kAXVisibleCharacterRangeAttribute as CFString), CFGetTypeID(raw) == AXValueGetTypeID() {
                        var range = CFRange(); if AXValueGetValue(raw as! AXValue, .cfRange, &range) { row["visibleRange"] = [range.location, range.length] }
                    }
                    var anchors: [[String: Any]] = []
                    for offset in offsets ?? [0, 36, 100, max(0, (expected as NSString).length - 30)] {
                        var range = CFRange(location: offset, length: 1), raw: CFTypeRef?
                        let parameter = AXValueCreate(.cfRange, &range)!
                        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &raw)
                        var anchor: [String: Any] = ["offset": offset, "AXError": error.rawValue]
                        if let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                            var box = CGRect.zero
                            if AXValueGetValue(raw as! AXValue, .cgRect, &box) { anchor["bounds"] = [Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)] }
                        }
                        anchors.append(anchor)
                    }
                    row["anchors"] = anchors
                } else if role == kAXScrollBarRole { row["value"] = value(element, kAXValueAttribute as CFString) as? Double }
                areas.append(row)
            }
            queue += value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        }
        guard areas.contains(where: { $0["textMatchesOwnedInput"] as? Bool == true }) else { throw CaptureError.message("TextEdit geometry did not match the independently generated input") }
        return ["fixtureCase": id, "readOnlyGeometry": true, "elements": areas, "clipboardTouched": false, "userContentUsed": false]
    }
}
