import AppKit
import ScreenCaptureKit

enum DiagnosticRecordingSource {
    static func permits(windowID: CGWindowID, processID: pid_t, bundle: URL?, fixture: URL) -> Bool {
        windowID>0 && processID>0 && bundle?.resolvingSymlinksInPath().standardizedFileURL == fixture.resolvingSymlinksInPath().standardizedFileURL
    }
    @MainActor static func require(_ window: SCWindow?) throws {
        guard let window, let owner=window.owningApplication,
              permits(windowID:window.windowID,processID:owner.processID,
                      bundle:NSRunningApplication(processIdentifier:owner.processID)?.bundleURL,
                      fixture:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ScrollFixtureTarget.app")) else {
            throw CaptureError.message("录制诊断只允许已启动的自有生成夹具，未开始捕获屏幕。")
        }
    }
}
