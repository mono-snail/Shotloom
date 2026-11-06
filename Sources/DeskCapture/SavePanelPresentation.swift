import AppKit

@MainActor
enum SavePanelPresentation {
    static func begin(_ panel: NSSavePanel, parent: NSWindow?,
                      completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard var host = parent else { panel.begin(completionHandler: completion); return }
        // AppKit queues a new sheet behind an existing sheet on the same host.
        // Use a subsheet so a save requested inside an editor is visible now.
        while let sheet = host.attachedSheet { host = sheet }
        panel.beginSheetModal(for: host, completionHandler: completion)
    }
}
