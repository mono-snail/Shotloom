import AppKit

/// Exercises the production history Copy and Edit Clipboard entry points using
/// generated files, a named pasteboard, and only windows created by this case.
@MainActor
enum DailyCaptureDiagnostic {
    static func run(root: URL) async throws -> [String: Any] {
        let board = NSPasteboard(name: .init("DeskCapture-QA-daily-\(UUID())"))
        defer { board.releaseGlobally() }
        let store = CaptureStore(directory: root.appendingPathComponent("daily-history"))
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        let source = await Task.detached(priority: .utility) { WorkflowCorpus.texture(width: 800, height: 600, seed: 42) }.value
        let record = try await store.addAsync(source, mode: .region, backingScale: 1)
        let file = store.url(for: record)
        let originalHash = try await Task.detached(priority: .utility) { try ArtifactIdentity.sha256(file) }.value
        var deliveries = 0, durations: [Double] = []
        app.onImageCopyCompleted = { deliveries += 1 }
        for index in 0..<30 {
            try Task.checkCancellation()
            let start = ProcessInfo.processInfo.systemUptime
            app.copy(record)
            await app.waitForPendingImageCopy()
            guard deliveries == index + 1 else { throw CaptureError.message("History copy did not deliver the latest file: \(app.notice ?? "none")") }
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        guard let data = board.data(forType: .png) else { throw CaptureError.message("History PNG missing from named pasteboard") }
        let unchanged = try await Task.detached(priority: .utility) { () throws -> Bool in
            guard let decoder = CGImageSourceCreateWithData(data as CFData, nil) else { throw CaptureError.message("Clipboard PNG is unreadable") }
            let result = try CaptureImageRead.decode(decoder)
            guard try ScrollFrameVisibility.matches(display: result, target: source, tolerance: 0) else { throw CaptureError.message("History clipboard PNG pixels changed") }
            return try ArtifactIdentity.sha256(file) == originalHash
        }.value
        guard unchanged else { throw CaptureError.message("Copy changed the history source file") }
        let text = "DeskCapture generated clipboard fixture — 仅用于隔离验证"
        board.clearContents(); board.setString(text, forType: .string)
        let revision = board.changeCount
        let oldWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
        app.editClipboard()
        let ownedWindows = NSApp.windows.filter { !oldWindows.contains(ObjectIdentifier($0)) }
        defer { ownedWindows.forEach { $0.close() } }
        func containsText(_ view: NSView) -> Bool {
            if let editor = view as? NSTextView, editor.string == text { return true }
            return view.subviews.contains { containsText($0) }
        }
        guard ownedWindows.contains(where: { $0.contentView.map(containsText) == true }),
              board.changeCount == revision, board.string(forType: .string) == text else {
            throw CaptureError.message("Edit Clipboard did not open the injected text or changed its source")
        }
        durations.sort()
        func percentile(_ fraction: Double) -> Double { durations[max(0, min(durations.count - 1, Int((Double(durations.count) * fraction).rounded(.up)) - 1))] }
        return ["iterations": durations.count, "pixels": "800x600", "pixelsCompared": 480_000,
                "maximumChannelError": 0, "copyP50Seconds": percentile(0.5), "copyP95Seconds": percentile(0.95),
                "copyMaxSeconds": durations.last!, "historyFileUnchanged": true,
                "clipboardEditUsedInjectedText": true, "namedPasteboardUnchangedAfterEdit": true,
                "userContentUsed": false, "systemClipboardTouched": false,
                "scope": "warm history-copy action through named pasteboard; not hotkey latency or cross-app paste compatibility"]
    }
}
