import AppKit

/// Query the selected ID directly. A WindowServer list's first entry is not a window identity.
struct CaptureWindowInfo {
    let id: CGWindowID
    let processID: pid_t
    let frame: CGRect
    let isOnScreen: Bool?

    static func read(_ id: CGWindowID) -> Self? {
        guard id != kCGNullWindowID,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        return resolve(id, in: windows)
    }

    static func resolve(_ id: CGWindowID, in windows: [[String: Any]]) -> Self? {
        // CGWindowListCreateDescriptionFromArray takes unboxed window IDs,
        // not an NSArray of NSNumber. Use the Swift-safe exact-window query,
        // then still check identity rather than trusting array position.
        guard id != kCGNullWindowID,
              let item = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let pid = item[kCGWindowOwnerPID as String] as? NSNumber,
              let bounds = item[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              !frame.isEmpty, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
        return Self(id: id, processID: pid.int32Value, frame: frame,
                    isOnScreen: (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue)
    }
}
