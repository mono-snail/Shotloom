// Interactive review only. Pass a generated fixture, never a user's recording.
import AppKit
import SwiftUI
@testable import DeskCapture

@main enum VideoEditingReview {
    static func main() {
        let app = NSApplication.shared
        let delegate = ReviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class ReviewDelegate: NSObject, NSApplicationDelegate {
    var window: VideoResultPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], home.hasPrefix("/tmp/deskcapture-edit-review-"),
              let fixture = ProcessInfo.processInfo.environment["DESKCAPTURE_REVIEW_VIDEO"] else { NSApp.terminate(nil); return }
        do {
            let input = URL(fileURLWithPath: home).appendingPathComponent("编辑演示.mp4")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: input)
            let main = NSMenu()
            let appItem = NSMenuItem(); let appMenu = NSMenu(); appItem.submenu = appMenu
            appMenu.addItem(withTitle: "退出查看", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); main.addItem(appItem)
            let edit = NSMenuItem(); let menu = NSMenu(title: "编辑"); edit.submenu = menu
            menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
            main.addItem(edit); NSApp.mainMenu = main
            let panel = VideoResultPanel(contentRect: NSRect(x: 120, y: 120, width: 1120, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "DeskCapture 视频编辑 · 隔离查看"
            panel.contentMinSize = NSSize(width: 780, height: 540); panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: VideoResultView(url: input, imported: true, close: { [weak panel] in panel?.performClose(nil) }))
            window = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } catch { print(error); NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
