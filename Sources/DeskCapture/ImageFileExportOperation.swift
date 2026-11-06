import AppKit

/// Own a save chooser and its encoder for the lifetime of the requesting window.
@MainActor final class ImageFileExportOperation {
    let panel = NSSavePanel()
    weak var parent: NSWindow?
    var task: Task<Void, Never>?
    private(set) var cancelled = false
    private var closeObserver: NSObjectProtocol?

    init(parent: NSWindow?) {
        self.parent = parent
        if let parent {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                }
        }
    }
    func cancel() {
        cancelled = true
        task?.cancel()
        panel.cancel(nil)
    }
    func finish() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil; task = nil
    }
}
