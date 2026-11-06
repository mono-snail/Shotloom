import AppKit
import ApplicationServices
import PDFKit

@MainActor
enum PreviewDocumentProbe {
    static func run() async throws -> [String: Any] {
        guard let folder = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_FIXTURE_DIR"],
              let id = ProcessInfo.processInfo.environment["DESKCAPTURE_NATIVE_CASE"], id.hasPrefix("P"),
              id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw CaptureError.message("Explicit generated PDF required") }
        let source = URL(fileURLWithPath: folder).appendingPathComponent("DeskCapture-Fixture-\(id).pdf")
        let content = try await CaptureEngine().content()
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.Preview" && ($0.title?.contains("DeskCapture-Fixture-\(id).pdf") ?? false) }
        guard windows.count == 1, let window = windows.first, let owner = window.owningApplication else { throw CaptureError.message("Exactly one owned Preview PDF required") }
        return try await Task.detached { try inspect(pid: owner.processID, id: id, source: source) }.value
    }
    nonisolated static func inspect(pid: pid_t, id: String, source: URL) throws -> [String: Any] {
        func value(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key, &result) == .success ? result : nil
        }
        func normalized(_ text: String) -> String { text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        guard let pdf = PDFDocument(url: source), pdf.pageCount == 6 else { throw CaptureError.message("Independent six-page PDF unreadable") }
        let expected = (0..<pdf.pageCount).map { normalized(pdf.page(at: $0)?.string ?? "") }
        guard expected.allSatisfy({ $0.contains("DeskCapture Fixture \(id)") }) else { throw CaptureError.message("Independent PDF case marker missing") }
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.12)
        guard let windows = value(app, kAXWindowsAttribute as CFString) as? [AXUIElement],
              let window = windows.first(where: { (value($0, kAXTitleAttribute as CFString) as? String)?.contains("DeskCapture-Fixture-\(id).pdf") == true }) else { throw CaptureError.message("Owned Preview AX window missing") }
        let rawDocument = value(window, kAXDocumentAttribute as CFString) ?? value(window, kAXURLAttribute as CFString)
        let documentURL = (rawDocument as? URL) ?? (rawDocument as? String).flatMap { URL(string: $0) }
        guard documentURL?.resolvingSymlinksInPath().standardizedFileURL == source.resolvingSymlinksInPath().standardizedFileURL else { throw CaptureError.message("Preview document URL does not match the owned frozen input") }
        var queue: [(AXUIElement, Int)] = [(window, -1)], rows: [[String: Any]] = [], matched: Set<Int> = []
        var textNodes: [Int: String] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !queue.isEmpty, rows.count < 1000, ProcessInfo.processInfo.systemUptime < deadline {
            let (element, parent) = queue.removeFirst(); AXUIElementSetMessagingTimeout(element, 0.12)
            let index = rows.count, role = value(element, kAXRoleAttribute as CFString) as? String ?? ""
            var row: [String: Any] = ["index": index, "parent": parent, "role": role]
            if let rawPoint = value(element, kAXPositionAttribute as CFString), let rawSize = value(element, kAXSizeAttribute as CFString),
               CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
                var point = CGPoint.zero, size = CGSize.zero
                if AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point), AXValueGetValue(rawSize as! AXValue, .cgSize, &size) {
                    row["bounds"] = [Double(point.x), Double(point.y), Double(size.width), Double(size.height)]
                }
            }
            if role == kAXScrollBarRole { row["value"] = value(element, kAXValueAttribute as CFString) as? Double }
            do {
                let strings = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { value(element, $0 as CFString) as? String }
                if role == kAXStaticTextRole, let text = strings.first(where: { !normalized($0).isEmpty }) {
                    textNodes[index] = normalized(text)
                }
                for string in strings {
                    if string.contains("DeskCapture Fixture \(id)") {
                        row["ownedTextPrefix"] = String(normalized(string).prefix(100))
                        row["ownedTextLength"] = normalized(string).count
                    }
                    if let page = expected.firstIndex(of: normalized(string)) {
                        row["matchesOwnedPage"] = page; matched.insert(page)
                    }
                }
            }
            rows.append(row)
            queue += (value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []).map { ($0, index) }
        }
        let pages = rows.filter { $0["role"] as? String == "AXPage" }.compactMap { $0["index"] as? Int }
        for (ordinal, pageIndex) in pages.enumerated() where ordinal < expected.count {
            let descendants = textNodes.keys.filter { index in
                var parent = rows[index]["parent"] as? Int ?? -1, traversed = 0
                while parent >= 0, parent < rows.count, traversed < rows.count {
                    if parent == pageIndex { return true }
                    parent = rows[parent]["parent"] as? Int ?? -1; traversed += 1
                }
                return false
            }.sorted { left, right in
                func path(_ index: Int) -> [Int] {
                    var result = [index], parent = rows[index]["parent"] as? Int ?? -1
                    while parent >= 0, parent < rows.count, parent != pageIndex {
                        result.append(parent); parent = rows[parent]["parent"] as? Int ?? -1
                    }
                    return result.reversed()
                }
                return path(left).lexicographicallyPrecedes(path(right))
            }
            // Preview exposes individual lines after layout, not one full-page
            // text value. Its ordered descendants must match the original PDF.
            let combined = descendants.compactMap { textNodes[$0] }.joined(separator: " ")
            rows[pageIndex]["pageTextLength"] = combined.count
            let ordered = combined == expected[ordinal]
            let inventory = combined.split(separator: " ").sorted() == expected[ordinal].split(separator: " ").sorted()
            if ordered || inventory {
                rows[pageIndex]["matchesOwnedPage"] = ordinal; matched.insert(ordinal)
                rows[pageIndex]["textInventoryMatches"] = true
                rows[pageIndex]["AXReadingOrderMatches"] = ordered
            }
            else {
                let actual = Array(combined), original = Array(expected[ordinal])
                let offset = zip(actual, original).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(actual.count, original.count)
                rows[pageIndex]["mismatchOffset"] = offset
                rows[pageIndex]["actualMismatch"] = String(actual.dropFirst(offset).prefix(40))
                rows[pageIndex]["expectedMismatch"] = String(original.dropFirst(offset).prefix(40))
            }
        }
        if let folder = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] {
            try JSONSerialization.data(withJSONObject: ["elements": rows, "expectedPagePrefix": String(expected[0].prefix(100)), "expectedPageLengths": expected.map(\.count)], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: folder).appendingPathComponent("preview-geometry.json"), options: .atomic)
        }
        guard matched.count == pdf.pageCount else { throw CaptureError.message("Preview AX page text does not match independent PDF: \(matched.sorted())") }
        return ["fixtureCase": id, "readOnlyGeometry": true, "independentPages": pdf.pageCount, "matchedPages": matched.sorted(), "elements": rows, "clipboardTouched": false, "userContentUsed": false]
    }
}
