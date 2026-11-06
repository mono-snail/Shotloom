import Foundation
import CryptoKit

/// A diagnostic must never inherit or write the installed app's preference
/// domain. CFFIXED_USER_HOME alone does not isolate cfprefsd on recent macOS.
enum AppPreferences {
    static let diagnosticDirectory = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"]
    static let standard = make(diagnosticDirectory: diagnosticDirectory)
    // An explicit, isolated UI review keeps the real single-instance gate and
    // restart path, while using temporary libraries/preferences and no hotkeys.
    static var isInteractivePermissionReview: Bool {
        diagnosticDirectory != nil && ProcessInfo.processInfo.environment["DESKCAPTURE_INTERACTIVE_PERMISSION_REVIEW"] == "1"
    }

    static func suiteName(for directory: String) -> String {
        let hash = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.deskcapture.qa." + String(hash.prefix(24))
    }

    static func make(diagnosticDirectory: String?, fallback: UserDefaults = .standard,
                     arguments: [String: Any]? = nil) -> UserDefaults {
        guard let diagnosticDirectory else { return fallback }
        let preferences = UserDefaults(suiteName: suiteName(for: diagnosticDirectory))!
        preferences.setVolatileDomain(arguments ?? fallback.volatileDomain(forName: UserDefaults.argumentDomain),
                                      forName: UserDefaults.argumentDomain)
        return preferences
    }

    static func clearDiagnosticDomain() {
        guard let diagnosticDirectory else { return }
        standard.removePersistentDomain(forName: suiteName(for: diagnosticDirectory))
    }
}
