import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let preferenceKey = "appLanguage"
    var id: String { rawValue }
    var title: String { self == .english ? "English" : "简体中文" }
}

/// UI copy is localized independently of persisted identifiers and user content.
enum L10n {
    // Resolve once per process: AppKit menus and existing windows must not end
    // up in different languages after a settings change. English is the default,
    // independently of the system's preferred language.
    static let language: String = {
        if let saved = AppPreferences.standard.string(forKey: AppLanguage.preferenceKey),
           let selected = AppLanguage(rawValue: saved) { return selected.rawValue }
        // Retain explicit language arguments used by isolated artwork previews.
        let arguments = AppPreferences.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let preferred = (arguments["AppleLanguages"] as? [String])?.first?.lowercased() {
            return preferred == "zh" || preferred.hasPrefix("zh-") ? "zh-Hans" : "en"
        }
        return AppLanguage.english.rawValue
    }()
    private static var resources: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
    private static let english: Bundle? = resources.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))
    private static let chinese: Bundle? = resources.url(forResource: "zh-Hans", withExtension: "lproj").flatMap(Bundle.init(url:))
    private static let arguments = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    static func translate(_ key: String) -> String {
        let fallback = english?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        return language == "zh-Hans" ? chinese?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback : fallback
    }
    static func text(_ value: Template) -> String {
        let format = translate(value.key)
        guard !value.values.isEmpty else { return format }
        let source = format as NSString
        var output = "", position = 0
        for match in arguments.matches(in: format, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: position, length: match.range.location - position))
            let number = Int(source.substring(with: match.range(at: 1))) ?? -1
            output += value.values.indices.contains(number) ? value.values[number] : source.substring(with: match.range)
            position = match.range.location + match.range.length
        }
        output += source.substring(from: position)
        return output
    }
    struct Template: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        var key: String
        var values: [String] = []
        init(stringLiteral value: String) { key = value }
        init(stringInterpolation value: StringInterpolation) { key = value.key; values = value.values }
        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var values: [String] = []
            init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity); values.reserveCapacity(interpolationCount) }
            mutating func appendLiteral(_ value: String) { key += value }
            mutating func appendInterpolation<T>(_ value: T) { key += "{\(values.count)}"; values.append(String(describing: value)) }
        }
    }
}
