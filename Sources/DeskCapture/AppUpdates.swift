import AppKit
import SwiftUI
#if !APP_STORE
import Sparkle
#endif

struct AppUpdateConfiguration: Equatable {
    let feed: URL
    let publicKey: Data
    static func read(_ info: [String: Any]) throws -> Self? {
        let rawURL = info["SUFeedURL"] as? String, rawKey = info["SUPublicEDKey"] as? String
        if rawURL == nil, rawKey == nil { return nil }
        guard let rawURL, rawURL.count <= 2048, let components = URLComponents(string: rawURL),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || (1...65535).contains(components.port!),
              let feed = components.url, let rawKey, let key = Data(base64Encoded: rawKey),
              key.count == 32, key.contains(where: { $0 != 0 }), key.base64EncodedString() == rawKey,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            throw CaptureError.message(L10n.text("更新配置无效；未开始检查或下载。"))
        }
        return .init(feed: feed, publicKey: key)
    }
}

struct AppUpdateActivity {
    var recording = false
    var capturing = false
    var processing = false
    var editing = false
    var blockReason: String? {
        if recording { return L10n.text("请先完成录制，再安装更新。") }
        if capturing { return L10n.text("请先完成当前捕获，再安装更新。") }
        if processing { return L10n.text("请等待当前处理或保存完成，再安装更新。") }
        if editing { return L10n.text("请先保存并关闭编辑内容，再安装更新。") }
        return nil
    }
}

#if APP_STORE
@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    let isRelaunchRequested = false
    var blockReason: () -> String? = { nil }
    func startIfConfigured() {}
    func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
    }
}
#else
@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var automaticChecks = false
    @Published private(set) var pendingInstallation = false
    @Published private(set) var status: String
    private(set) var isRelaunchRequested = false
    private let configuration: AppUpdateConfiguration?
    private let disabled: Bool
    private var controller: SPUStandardUpdaterController?
    private var pendingInstaller: (() -> Void)?
    var blockReason: () -> String? = { nil }
    var available: Bool { configuration != nil && !disabled }

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         diagnostic: Bool = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] != nil) {
        configuration = try? AppUpdateConfiguration.read(info)
        disabled = diagnostic
        status = diagnostic ? L10n.text("此测试会话不检查在线更新。") : configuration == nil ? L10n.text("此版本尚未连接更新服务。") : L10n.text("更新会在下载后验证，安装前保留你的处理与编辑。")
        super.init()
    }
    func startIfConfigured() {
        guard available, controller == nil else { return }
        let candidate = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try candidate.updater.start()
            candidate.updater.clearFeedURLFromUserDefaults()
            controller = candidate; automaticChecks = candidate.updater.automaticallyChecksForUpdates
        } catch { status = L10n.text("更新服务暂不可用，请稍后重试。") }
    }
    func setAutomaticChecks(_ enabled: Bool) {
        startIfConfigured()
        guard let controller else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        // Background checking is separate from downloading/installing code.
        controller.updater.automaticallyDownloadsUpdates = false
        automaticChecks = enabled
    }
    func checkForUpdates() {
        if pendingInstallation {
            if !resumePendingInstallation() { showMessage(blockReason() ?? status) }
            return
        }
        guard available else { showMessage(status); return }
        if let reason = blockReason() { showMessage(reason); return }
        startIfConfigured()
        guard let controller else { showMessage(status); return }
        controller.checkForUpdates(nil)
    }
    @discardableResult func postponeInstallationIfNeeded(_ install: @escaping () -> Void) -> Bool {
        guard let reason = blockReason() else { return false }
        pendingInstaller = install; pendingInstallation = true
        status = L10n.text("更新已准备好。\(reason)然后选择继续安装。")
        return true
    }
    @discardableResult func resumePendingInstallation() -> Bool {
        guard let install = pendingInstaller, blockReason() == nil else { return false }
        pendingInstaller = nil; pendingInstallation = false; isRelaunchRequested = true
        install(); return true
    }
    private func showMessage(_ message: String) {
        let alert = NSAlert(); alert.messageText = L10n.text("DeskCapture 更新"); alert.informativeText = message
        alert.addButton(withTitle: L10n.text("好")); NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feed.absoluteString }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if let reason = blockReason() { throw NSError(domain: "DeskCapture.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { isRelaunchRequested = true }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishCycle(error: error)
    }
    func finishCycle(error: Error?) {
        // A successful cycle can still have an installation/relaunch pending.
        // Keep the final application termination guard armed until it finishes.
        guard error != nil else { return }
        isRelaunchRequested = false
        pendingInstaller = nil; pendingInstallation = false
        status = L10n.text("本次更新检查未完成，已有应用保留。")
    }
}
#endif

struct AppUpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
#if APP_STORE
        SettingsRow(title: L10n.text("应用更新")) {
            Button(L10n.text("在 App Store 中检查更新…")) { updates.checkForUpdates() }
                .buttonStyle(StudioButtonStyle(command: true))
        }
#else
        VStack(alignment: .leading, spacing: 0) {
            SettingsToggle(title: L10n.text("自动检查更新"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.available)
            Divider()
            SettingsRow(title: L10n.text("应用更新")) {
                Button(updates.pendingInstallation ? L10n.text("继续安装已下载更新…") : L10n.text("检查更新…")) { updates.checkForUpdates() }
                    .buttonStyle(StudioButtonStyle(command: true))
            }
            if !updates.available || updates.pendingInstallation || updates.status != L10n.text("更新会在下载后验证，安装前保留你的处理与编辑。") {
                Text(updates.status).font(.system(size: 13)).foregroundStyle(Palette.muted)
                    .textSelection(.enabled).padding(.vertical, 8)
            }
        }
#endif
    }
}
