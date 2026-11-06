// Exercise the production import entry with temporary preferences and media.
import AppKit

@MainActor
final class VideoEditorPreviewDelegate: NSObject, NSApplicationDelegate {
    var coordinator: AppCoordinator!
    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        coordinator.importVideo()
    }
}
@main enum VideoEditorPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = VideoEditorPreviewDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
