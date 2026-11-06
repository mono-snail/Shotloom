import Foundation

enum AppIdentity {
    // Preserve existing storage names, URL schemes and project UTIs independently of the app bundle identifier.
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DeskCapture"
}

/// Public website identity; in-app support is presented by ShotloomSupportWindow.
enum AppSupport {
    static let email = "support@monoware.app"
    static var privacyURL: URL {
        URL(string: "https://shotloom.monoware.app/" + (L10n.language == "zh-Hans" ? "zh/privacy/" : "privacy/"))!
    }
    static var url: URL {
        var components = URLComponents(string: "https://support.monoware.app/")!
        components.queryItems = [URLQueryItem(name: "product", value: "shotloom")]
        return components.url!
    }
}
