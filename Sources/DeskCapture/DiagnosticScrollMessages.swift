import Foundation

/// Diagnostic assertions must use the same language as the application under test.
/// These checks supplement capture state and pixel-preservation assertions.
enum DiagnosticScrollMessages {
    enum Reason: CaseIterable {
        case visibility, changing, obscured

        func fragment(language: String) -> String {
            switch (self, language == AppLanguage.simplifiedChinese.rawValue) {
            case (.visibility, true): "无法确认完整可见"
            case (.visibility, false): "full visibility cannot be confirmed"
            case (.changing, true): "页面持续变化"
            case (.changing, false): "The page keeps changing"
            case (.obscured, true): "遮挡"
            case (.obscured, false): "obscured"
            }
        }
    }

    static func matches(_ message: String?, reason: Reason, language: String = L10n.language) -> Bool {
        guard let message else { return false }
        return message.range(of: reason.fragment(language: language), options: .caseInsensitive) != nil
    }
}
