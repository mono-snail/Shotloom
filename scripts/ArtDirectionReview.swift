// Interactive design canvas, not a test runner. All media and preferences are isolated.
import AppKit
import SwiftUI
import ImageIO
@testable import DeskCapture

@main enum ArtDirectionReview {
    @MainActor static func main() {
        let home = "/tmp/shotloom-art-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("CFFIXED_USER_HOME", home, 1)
        setenv("DESKCAPTURE_DIAGNOSTIC_DIR", home, 1)
        let output = ProcessInfo.processInfo.environment["SHOTLOOM_ART_OUTPUT"] ?? (Bundle.main.object(forInfoDictionaryKey: "ShotloomArtOutput") as! String)
        setenv("SHOTLOOM_ART_OUTPUT", output, 1)
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": [CommandLine.arguments.contains("--english") ? "en" : "zh-Hans"]], forName: UserDefaults.argumentDomain)
        let application = NSApplication.shared
        print("Review: AppKit ready"); fflush(stdout)
        application.setActivationPolicy(.regular)
        let delegate = ArtDirectionReviewDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor final class ArtDirectionReviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var coordinator: AppCoordinator!
    private var store: CaptureStore!
    private var sample: CGImage!
    private var record: CaptureRecord!
    private var page = 0
    private var dark = false
    private var compact = false
    private var snapshot = 0
    private let board = NSPasteboard(name: .init("Shotloom.ArtReview"))
    private var output: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Review: delegate entered"); fflush(stdout)
        compact = CommandLine.arguments.contains("--minimum")
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              home.hasPrefix("/tmp/shotloom-art-"),
              let destination = ProcessInfo.processInfo.environment["SHOTLOOM_ART_OUTPUT"] else {
            fatalError("Requires isolated review home and explicit snapshot destination")
        }
        output = URL(fileURLWithPath: destination, isDirectory: true)
        store = CaptureStore(directory: URL(fileURLWithPath: home).appendingPathComponent("history", isDirectory: true), pruneOnInit: false)
        print("Review: isolated store ready"); fflush(stdout)
        coordinator = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        print("Review: coordinator ready"); fflush(stdout)
        // Bundled, non-private product sample. No screen, microphone or camera session.
        guard let image = try? WorkflowExampleImage.load() else { fatalError("Missing bundled sample") }
        sample = image
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Review", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)
        let menu = NSMenu(title: "Design")
        for (index, name) in ["Launcher", "Beautify", "History", "History List", "Image Editor", "Settings", "Source Chooser"].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(changePage(_:)), keyEquivalent: String(index + 1))
            item.tag = index; item.target = self; item.keyEquivalentModifierMask = [.command, .option]; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (name, action, key) in [("Toggle Appearance", #selector(toggleAppearance), "d"),
                                     ("Toggle Minimum Size", #selector(toggleSize), "m"),
                                     ("Save Interface Snapshot", #selector(saveSnapshot), "s")] {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = [.command, .option]; menu.addItem(item)
        }
        let design = NSMenuItem(title: "Design", action: nil, keyEquivalent: ""); design.submenu = menu; main.addItem(design)
        NSApp.mainMenu = main
        Task {
            do {
                record = try await store.addAsync(image, mode: .region)
                if CommandLine.arguments.contains("--render-artifacts") {
                    // Offscreen design artifacts, without UI automation or assertions.
                    for appearance in [false, true] {
                        dark = appearance
                        for item in [0, 1, 2, 3, 4, 5, 6] {
                            page = item; showPage()
                            try await Task.sleep(for: .milliseconds(900))
                            await saveArtifact()
                        }
                    }
                    NSApp.terminate(nil)
                } else { showPage() }
            } catch {
                print("Review setup failed: \(error.localizedDescription)"); fflush(stdout)
                if CommandLine.arguments.contains("--render-artifacts") { NSApp.terminate(nil) }
                else { window.title = error.localizedDescription; window.makeKeyAndOrderFront(nil) }
            }
        }
    }

    @objc private func changePage(_ sender: NSMenuItem) { page = sender.tag; showPage() }
    @objc private func toggleAppearance() { dark.toggle(); showPage() }
    @objc private func toggleSize() { compact.toggle(); resize() }
    private func resize() {
        let size: CGSize = page == 0 ? .init(width: 328, height: 580) :
            (page == 2 || page == 3 ? (compact ? StudioMetrics.libraryMinimum : .init(width: 880, height: 620)) :
             page == 5 ? StudioMetrics.settingsMinimum : compact ? StudioMetrics.workspaceMinimum : .init(width: 960, height: 660))
        window.contentMinSize = page == 0 ? size : page == 5 ? StudioMetrics.settingsMinimum :
            (page == 2 || page == 3 ? StudioMetrics.libraryMinimum : StudioMetrics.workspaceMinimum)
        window.setContentSize(size); window.center()
    }
    private func showPage() {
        let scheme: ColorScheme = dark ? .dark : .light
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let content: AnyView
        switch page {
        case 0: content = AnyView(CompactLauncherView(app: coordinator, store: store).frame(maxHeight: .infinity, alignment: .top).background(Palette.ink))
        case 1: content = AnyView(BeautifyWorkspaceView(store: store, pasteboard: board, source: sample, copy: { _ in }, save: { _ in }, close: {}))
        case 2, 3: content = AnyView(HistoryView(app: coordinator, store: store, initialGallery: page == 2))
        case 4: content = AnyView(EditorView(app: coordinator, store: store, document: AnnotationDocument(image: sample), record: record, parent: window))
        case 5: content = AnyView(SettingsView(app: coordinator))
        default: content = AnyView(BeautifyWorkspaceView(store: store, pasteboard: board, copy: { _ in }, save: { _ in }, close: {}))
        }
        window.title = "Shotloom · Design Review"
        window.contentView = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
        resize()
        if !CommandLine.arguments.contains("--render-artifacts") {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func saveSnapshot() {
        Task { await saveArtifact() }
    }
    private func saveArtifact() async {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        snapshot += 1
        let name = ["launcher", "beautify", "history", "history-list", "editor", "settings", "source"][page]
        let url = output.appendingPathComponent("\(snapshot)-\(name)-\(dark ? "dark" : "light")-\(Int(view.bounds.width))x\(Int(view.bounds.height)).png")
        await Task.detached(priority: .utility) {
            do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { print("Snapshot failed: \(error.localizedDescription)"); return }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            if CGImageDestinationFinalize(dest) { print("Snapshot: \(url.path)") }
        }.value
    }
}
