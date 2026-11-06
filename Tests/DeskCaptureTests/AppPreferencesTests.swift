import XCTest
@testable import DeskCapture

final class AppPreferencesTests: XCTestCase {
    func testOrdinaryLaunchKeepsTheExistingPreferenceStore() {
        let name = "DeskCapture-preferences-fallback-\(UUID())"
        let fallback = UserDefaults(suiteName: name)!
        defer { fallback.removePersistentDomain(forName: name) }
        fallback.set("existing", forKey: "appearanceMode")
        let actual = AppPreferences.make(diagnosticDirectory: nil, fallback: fallback)
        XCTAssertTrue(actual === fallback)
        XCTAssertEqual(actual.string(forKey: "appearanceMode"), "existing")
    }

    func testDiagnosticWritesCannotInheritOrReplaceTheExistingDomain() {
        let directory = "/tmp/DeskCapture-preferences-\(UUID())"
        let fallbackName = "DeskCapture-preferences-fallback-\(UUID())"
        let fallback = UserDefaults(suiteName: fallbackName)!
        let suite = AppPreferences.suiteName(for: directory)
        let isolated = AppPreferences.make(diagnosticDirectory: directory, fallback: fallback, arguments: [:])
        defer {
            fallback.removePersistentDomain(forName: fallbackName)
            isolated.removePersistentDomain(forName: suite)
        }
        fallback.set("user-setting", forKey: "appearanceMode")
        XCTAssertNil(isolated.string(forKey: "appearanceMode"))
        isolated.set("dark", forKey: "appearanceMode")
        isolated.set(Data([1, 2, 3]), forKey: "lastSelection")
        XCTAssertEqual(fallback.string(forKey: "appearanceMode"), "user-setting")
        XCTAssertNil(fallback.data(forKey: "lastSelection"))
        XCTAssertEqual(isolated.persistentDomain(forName: suite)?["appearanceMode"] as? String, "dark")
        XCTAssertNotEqual(suite, AppPreferences.suiteName(for: directory + "-other"))
    }

    func testDiagnosticLaunchArgumentsRemainVolatile() {
        let directory = "/tmp/DeskCapture-preferences-\(UUID())"
        let isolated = AppPreferences.make(diagnosticDirectory: directory,
            arguments: ["primaryShortcutEnabled": false, "historyRetentionDays": 0])
        let suite = AppPreferences.suiteName(for: directory)
        defer { isolated.removePersistentDomain(forName: suite) }
        XCTAssertFalse(isolated.bool(forKey: "primaryShortcutEnabled"))
        XCTAssertEqual(isolated.integer(forKey: "historyRetentionDays"), 0)
        XCTAssertNil(isolated.persistentDomain(forName: suite)?["primaryShortcutEnabled"])
    }
}
