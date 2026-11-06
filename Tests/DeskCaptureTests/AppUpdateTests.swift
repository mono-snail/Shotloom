import XCTest
import CryptoKit
@testable import DeskCapture

final class AppUpdateTests: XCTestCase {
    private func info() -> [String: Any] {
        ["SUFeedURL": "https://updates.example.invalid/appcast.xml", "SUPublicEDKey": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true]
    }
    func testUpdateConfigurationRequiresHTTPSAndPublicArchiveAndFeedAuthentication() throws {
        XCTAssertNil(try AppUpdateConfiguration.read([:]))
        let valid = info(); XCTAssertNotNil(try AppUpdateConfiguration.read(valid))
        for url in ["http://updates.example.invalid/feed", "file:///tmp/feed", "https://user:password@example.invalid/feed", "https://example.invalid/feed#part", "https://example.invalid/feed#", "https://example.invalid:0/feed", "https://example.invalid:bad/feed", "not a url"] {
            var changed = valid; changed["SUFeedURL"] = url; XCTAssertThrowsError(try AppUpdateConfiguration.read(changed))
        }
        for key in ["", "invalid", Data(repeating: 0, count: 32).base64EncodedString(), Data(repeating: 1, count: 31).base64EncodedString()] {
            var changed = valid; changed["SUPublicEDKey"] = key; XCTAssertThrowsError(try AppUpdateConfiguration.read(changed))
        }
        for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
            var changed = valid; changed[key] = false; XCTAssertThrowsError(try AppUpdateConfiguration.read(changed))
        }
    }
    @MainActor func testUnconfiguredAndDiagnosticSessionsNeverCreateAnUpdaterOrEnableChecks() {
        let missing = AppUpdateController(info: [:], diagnostic: false)
        XCTAssertFalse(missing.available); missing.startIfConfigured(); missing.setAutomaticChecks(true)
        XCTAssertFalse(missing.automaticChecks)
        let diagnostic = AppUpdateController(info: info(), diagnostic: true)
        XCTAssertFalse(diagnostic.available); diagnostic.startIfConfigured(); diagnostic.setAutomaticChecks(true)
        XCTAssertFalse(diagnostic.automaticChecks)
    }
    @MainActor func testPendingInstallDoesNotRunUntilActivityIsSafeAndCanOnlyResumeOnce() {
        let updater = AppUpdateController(info: [:], diagnostic: true)
        var busy = true, installs = 0
        updater.blockReason = { busy ? "Editing" : nil }
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installs += 1 })
        XCTAssertTrue(updater.pendingInstallation); XCTAssertFalse(updater.resumePendingInstallation()); XCTAssertEqual(installs, 0)
        busy = false
        XCTAssertTrue(updater.resumePendingInstallation()); XCTAssertEqual(installs, 1)
        XCTAssertTrue(updater.isRelaunchRequested); XCTAssertFalse(updater.pendingInstallation)
        XCTAssertFalse(updater.resumePendingInstallation()); XCTAssertEqual(installs, 1)
    }
    func testActivityGuardsRecordingCaptureProcessingAndDrafts() {
        XCTAssertNil(AppUpdateActivity().blockReason)
        XCTAssertNotNil(AppUpdateActivity(recording: true).blockReason)
        XCTAssertNotNil(AppUpdateActivity(capturing: true).blockReason)
        XCTAssertNotNil(AppUpdateActivity(processing: true).blockReason)
        XCTAssertNotNil(AppUpdateActivity(editing: true).blockReason)
    }
    @MainActor func testAbortedCycleCannotReplayAStaleInstallerAndSuccessfulCycleKeepsRelaunchGuard() {
        let updater = AppUpdateController(info: [:], diagnostic: true)
        var busy = true, installs = 0
        updater.blockReason = { busy ? "Editing" : nil }
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installs += 1 })
        updater.finishCycle(error: NSError(domain: "OwnedFixture", code: 1))
        busy = false
        XCTAssertFalse(updater.resumePendingInstallation()); XCTAssertEqual(installs, 0)
        XCTAssertFalse(updater.pendingInstallation)
        busy = true
        XCTAssertTrue(updater.postponeInstallationIfNeeded { installs += 1 })
        busy = false; XCTAssertTrue(updater.resumePendingInstallation())
        updater.finishCycle(error: nil)
        XCTAssertTrue(updater.isRelaunchRequested); XCTAssertEqual(installs, 1)
    }
}
