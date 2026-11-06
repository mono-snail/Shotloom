import AppKit
import Darwin
import OSLog

// This helper waits for the parent to exit before requesting a fresh launch.
// Reusing a just-terminated Launch Services record can target the dead PID.
let arguments = CommandLine.arguments
guard (3...4).contains(arguments.count), let parentPID = Int32(arguments[1]), parentPID == getppid(),
      let parent = NSRunningApplication(processIdentifier: parentPID),
      let parentURL = parent.bundleURL, let identifier = parent.bundleIdentifier else { exit(2) }
let applicationURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
guard applicationURL.pathExtension == "app",
      parentURL.standardizedFileURL.resolvingSymlinksInPath() == applicationURL else { exit(2) }
let chinese = arguments.count == 4 && arguments[3] == "zh-Hans"
let logger = Logger(subsystem: "app.monoware.shotloom.relaunch", category: "handoff")
var launching = false
var completed = false
var attempts = 0
let exitSource = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)

func existingApplication() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
        !$0.isTerminated && $0.processIdentifier != parentPID && $0.processIdentifier != getpid()
            && !(kill($0.processIdentifier, 0) == -1 && errno == ESRCH)
    }
}

func fail(_ error: NSError) {
    guard !completed else { return }
    completed = true
    logger.error("Reopen failed after \(attempts) attempts: \(error.domain, privacy: .public) \(error.code)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    let name = applicationURL.deletingPathExtension().lastPathComponent
    alert.messageText = chinese ? "无法重新打开 \(name)" : "Unable to reopen \(name)"
    let recovery = chinese
        ? "应用已退出。请从原安装位置手动打开；无需更改屏幕录制权限。"
        : "The app has quit. Open it manually from its original location. You do not need to change Screen Recording access."
    alert.informativeText = "\(error.localizedDescription)\n\n\(recovery)\n\n\(error.domain) (\(error.code))"
    alert.addButton(withTitle: chinese ? "好" : "OK")
    app.activate(ignoringOtherApps: true)
    alert.runModal()
    exit(1)
}

func attemptLaunch() {
    guard !completed else { return }
    // A system-triggered reopen or a user's click can have already restarted it.
    if let existing = existingApplication() {
        existing.activate(options: [.activateAllWindows])
        logger.info("Reused an already restarted app, PID \(existing.processIdentifier)")
        exit(0)
    }
    attempts += 1
    let configuration = NSWorkspace.OpenConfiguration()
    // Only used AFTER the original process exited. This avoids the dead-process
    // reuse race; the main app's atomic single-instance gate remains authoritative.
    configuration.createsNewApplicationInstance = true
    configuration.allowsRunningApplicationSubstitution = false
    configuration.activates = true
    // Preserve isolation only for the explicit interactive review. Ordinary
    // restarts receive no test arguments or preference overrides.
    let environment = ProcessInfo.processInfo.environment
    if environment["DESKCAPTURE_INTERACTIVE_PERMISSION_REVIEW"] == "1",
       let directory = environment["DESKCAPTURE_DIAGNOSTIC_DIR"] {
        configuration.environment = ["DESKCAPTURE_INTERACTIVE_PERMISSION_REVIEW": "1",
                                     "DESKCAPTURE_DIAGNOSTIC_DIR": directory]
    }
    logger.info("Requesting post-exit launch, attempt \(attempts)")
    NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
        DispatchQueue.main.async {
            guard !completed else { return }
            if let application, error == nil, !application.isTerminated {
                logger.info("Reopened app with PID \(application.processIdentifier)")
                completed = true
                exit(0)
            }
            let failure = (error as NSError?) ?? NSError(domain: NSOSStatusErrorDomain, code: -600)
            logger.error("Launch returned \(failure.domain, privacy: .public) \(failure.code)")
            // These are process/Launch Services transition failures, not a reason
            // to reset permissions or bypass the app's single-instance protection.
            let transientCodes: Set<Int> = [-600, -609, -10810]
            if attempts < 3, failure.domain == NSOSStatusErrorDomain, transientCodes.contains(failure.code) {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250 * attempts)) { attemptLaunch() }
            } else { fail(failure) }
        }
    }
}

func parentExited() {
    guard !launching else { return }
    launching = true
    exitSource.cancel()
    logger.info("Parent \(parentPID) exited; waiting for Launch Services teardown")
    // Give Launch Services one run-loop transition to retire the old app record.
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { attemptLaunch() }
}

exitSource.setEventHandler { parentExited() }
exitSource.resume()
logger.info("Exit observer ready for parent \(parentPID)")
FileHandle.standardOutput.write(Data("ready\n".utf8))
try? FileHandle.standardOutput.close()
if parent.isTerminated || (kill(parentPID, 0) == -1 && errno == ESRCH) { parentExited() }
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    guard !completed else { return }
    if launching { fail(NSError(domain: NSOSStatusErrorDomain, code: -1712)) }
    else { exit(3) } // Parent kept running: never open a second instance.
}
RunLoop.main.run()
