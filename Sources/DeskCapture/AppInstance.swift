import AppKit
import Darwin

/// Acquired before libraries, hotkeys, menus or permission requests are created.
/// The process registry covers copies in different locations; flock also closes
/// the simultaneous-start race for copies using the same app container.
@MainActor
final class AppInstanceController {
    private var lockDescriptor: Int32 = -1
    private var launchTask: Task<Void, Never>?

    static var isIsolatedInvocation: Bool {
        if ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] != nil,
           !AppPreferences.isInteractivePermissionReview { return true }
        let modes: Set<String> = ["--quality-diagnostic", "--capture-diagnostic", "--studio-export-diagnostic",
            "--recording-smoke-test", "--camera-recording-smoke-test", "--ocr-reference-benchmark",
            "--ocr-reference-editor", "--capture-ui-benchmark", "--workflow-benchmark"]
        return CommandLine.arguments.contains { modes.contains($0) }
    }

    private func existingApplication(onlyOlder: Bool) -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let current = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier }
            .filter { !(kill($0.processIdentifier, 0) == -1 && errno == ESRCH) }
            .filter {
                guard onlyOlder else { return true }
                let otherDate = $0.launchDate ?? .distantPast
                let currentDate = current.launchDate ?? .distantPast
                return otherDate == currentDate ? $0.processIdentifier < current.processIdentifier : otherDate < currentDate
            }
            .min { ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier) }
    }

    func begin(onReady: @escaping () -> Void) {
        if Self.isIsolatedInvocation { onReady(); return }
        launchTask = Task { [weak self] in
            guard let self else { return }
            if self.activateExistingApplication() { return }
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: false)
                    .appendingPathComponent("DeskCapture", isDirectory: true)
                let path = directory.appendingPathComponent("interactive-instance.lock").path
                let descriptor = try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
                    let code = errno
                    Darwin.close(descriptor)
                    if code == EWOULDBLOCK { return Int32(-1) }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }.value
                guard descriptor >= 0 else {
                    // Allow the lock owner to finish registering with AppKit.
                    for _ in 0..<10 {
                        if self.activateExistingApplication(onlyOlder: false) { return }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    self.stopLaunch(L10n.text("已有一个应用实例正在启动，请稍后使用菜单栏中的应用。"))
                    return
                }
                self.lockDescriptor = descriptor
                // Another copy can have a different sandbox/home directory.
                if self.activateExistingApplication() { return }
                onReady()
            } catch { self.stopLaunch(error.localizedDescription) }
        }
    }

    @discardableResult private func activateExistingApplication(onlyOlder: Bool = true) -> Bool {
        guard let existing = existingApplication(onlyOlder: onlyOlder) else { return false }
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    private func stopLaunch(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text("无法启动应用")
        alert.informativeText = reason
        alert.addButton(withTitle: L10n.text("退出"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    deinit {
        // Never unlink the lock file: replacing its inode breaks mutual exclusion.
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }
}
