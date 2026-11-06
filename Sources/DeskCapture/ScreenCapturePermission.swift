import AppKit
import SwiftUI

/// A launch gate, not a capture-time warning. Once this process finds access
/// unavailable, setup stays visible until the user restarts the application.
@MainActor
final class ScreenCapturePermissionController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var checking = false
    @Published private(set) var restarting = false
    @Published private(set) var issue: String?
    private weak var app: AppCoordinator?
    private let onReady: () -> Void
    private var window: NSWindow?
    private var checkTask: Task<Void, Never>?
    private var ready = false
    private var checkGeneration = UUID()
    private var relaunchProcess: Process?
    private var relaunchPipe: Pipe?
    private var relaunchWatchdog: Task<Void, Never>?
    private var relaunchOutput = ""
    private var terminating = false

    init(app: AppCoordinator, onReady: @escaping () -> Void) {
        self.app = app
        self.onReady = onReady
        super.init()
    }

    func start() {
        app?.permission = false
        guard CaptureEngine.hasPermission else { requireSetup(); return }
        confirmLaunchAccess()
    }

    @discardableResult func allowEntry() -> Bool {
        guard ready else { show(); return false }
        return true
    }

    func requireSetup() {
        checkGeneration = UUID()
        checkTask?.cancel(); checkTask = nil
        checking = false
        ready = false
        app?.permission = false
        show()
    }

    func applicationDidBecomeActive() {
        guard !ready, !restarting, window != nil else { return }
        // Returning from Settings never bypasses the required restart step.
        show()
    }

    private func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = L10n.text("屏幕捕获权限")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 420)
            window.delegate = self
            window.contentView = NSHostingView(rootView: ScreenCapturePermissionView(controller: self))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { ready }

    func openSettings() {
        guard !restarting, !checking else { return }
        issue = nil
        // This is navigation, not an authorization request. Requesting access
        // here would show a second system dialog before opening Settings.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        if !NSWorkspace.shared.open(url) {
            issue = L10n.text("无法打开系统设置，请前往“隐私与安全性”中的“屏幕与系统音频录制”。")
        }
    }

    func revealApplication() {
        guard !restarting else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func confirmLaunchAccess() {
        guard checkTask == nil, !restarting else { return }
        checking = true
        issue = nil
        let generation = checkGeneration
        checkTask = Task { [weak self] in
            do {
                try await CaptureEngine().confirmScreenshotAccess()
                try Task.checkCancellation()
                guard let self, self.checkGeneration == generation else { return }
                self.checking = false
                self.checkTask = nil
                self.ready = true
                self.app?.permission = true
                self.window?.orderOut(nil)
                self.onReady()
            } catch {
                guard let self, !Task.isCancelled, self.checkGeneration == generation else { return }
                self.checking = false
                self.checkTask = nil
                if case CaptureError.permission = error {
                    self.issue = nil
                } else { self.issue = error.localizedDescription }
                self.show()
            }
        }
    }

    func restart() {
        guard !restarting else { return }
        // The initial setup has no documents. If permission is revoked later,
        // preserve in-flight work and editors instead of terminating them.
        if let reason = app?.updateBlockReason { issue = reason; return }
        restarting = true
        checkGeneration = UUID()
        checkTask?.cancel(); checkTask = nil; checking = false
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ShotloomRelaunch")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            restartFailed(L10n.text("重启组件不可用，请退出后从原安装位置重新打开应用。"))
            return
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, L10n.language]
        process.standardOutput = pipe
        relaunchProcess = process; relaunchPipe = pipe; relaunchOutput = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, let process, self.relaunchProcess === process, !self.terminating else { return }
                self.relaunchOutput += String(decoding: data, as: UTF8.self)
                if self.relaunchOutput.contains("ready\n") {
                    // The helper now waits for this process to exit before it
                    // asks Launch Services to start this exact bundle again.
                    self.applicationWillTerminate()
                    NSApp.terminate(nil)
                }
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, let process, self.relaunchProcess === process, !self.terminating else { return }
                self.restartFailed(L10n.text("重启组件未能就绪，当前应用已保留。请退出后重新打开。"))
            }
        }
        relaunchWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, !self.terminating else { return }
            self.restartFailed(L10n.text("重启组件未能就绪，当前应用已保留。请退出后重新打开。"))
        }
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { try process.run() }.value
                try? pipe.fileHandleForWriting.close()
                // A timed-out launch can finish after the user retries. It must
                // not leave a helper that reopens the app on a later manual quit.
                if let self, !self.terminating, self.relaunchProcess !== process, process.isRunning {
                    process.terminate()
                }
            } catch {
                guard let self, !self.terminating, self.relaunchProcess === process else { return }
                self.restartFailed(error.localizedDescription)
            }
        }
    }

    private func restartFailed(_ message: String) {
        relaunchWatchdog?.cancel(); relaunchWatchdog = nil
        relaunchPipe?.fileHandleForReading.readabilityHandler = nil
        relaunchProcess?.terminationHandler = nil
        if relaunchProcess?.isRunning == true { relaunchProcess?.terminate() }
        relaunchProcess = nil; relaunchPipe = nil
        restarting = false
        issue = message
    }

    func applicationWillTerminate() {
        terminating = true
        checkGeneration = UUID(); checkTask?.cancel()
        relaunchWatchdog?.cancel()
        relaunchPipe?.fileHandleForReading.readabilityHandler = nil
        relaunchProcess?.terminationHandler = nil
        // Keep the acknowledged helper alive; it owns the subsequent reopen.
    }

}

private struct ScreenCapturePermissionView: View {
    @ObservedObject var controller: ScreenCapturePermissionController

    var body: some View {
        StudioDialog(title: L10n.text("开启屏幕录制权限"), symbol: "lock.shield", width: 560, height: 420) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(L10n.text("当前没有可用的屏幕录制权限"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ice)
                    Text(L10n.text("\(AppIdentity.name) 需要这项权限来获取屏幕截图。开启权限并重启应用后，才能开始使用。"))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("1. 在系统设置中开启权限"))
                            .fontWeight(.semibold)
                        Text(L10n.text("前往“隐私与安全性 → 屏幕与系统音频录制”，开启 \(AppIdentity.name)。"))
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup(L10n.text("设置里没有找到应用？")) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.text("点击列表下方的“+”，添加当前安装的 \(AppIdentity.name)，然后开启权限。"))
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(L10n.text("在访达中显示此应用")) { controller.revealApplication() }
                                    .disabled(controller.restarting)
                            }
                            .padding(.top, 8)
                        }
                        Text(L10n.text("2. 退出并重新打开应用"))
                            .fontWeight(.semibold)
                        Text(L10n.text("若系统提示“退出并重新打开”，按提示操作即可；若选择了“稍后”，请回到这里点击“重启应用”。无需重启电脑。"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue = controller.issue {
                        Text(issue).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if controller.checking || controller.restarting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(controller.restarting ? L10n.text("正在重新打开应用…") : L10n.text("正在确认屏幕捕获权限…"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button(L10n.text("退出")) { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
            Spacer()
            Button(L10n.text("重启应用")) { controller.restart() }
                .disabled(controller.restarting)
            Button(L10n.text("打开系统设置")) { controller.openSettings() }
                .buttonStyle(StudioButtonStyle(primary: true, command: true))
                .keyboardShortcut(.defaultAction)
                .disabled(controller.restarting || controller.checking)
        }
    }
}
