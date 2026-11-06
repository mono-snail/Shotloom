import XCTest
@testable import DeskCapture

final class DiagnosticScrollMessagesTests: XCTestCase {
    func testEnglishDiagnosticsRecognizeEnglishWarnings() {
        XCTAssertTrue(DiagnosticScrollMessages.matches("Another window covers the selection, so full visibility cannot be confirmed. Move it before continuing. Existing segments will be kept.", reason: .visibility, language: "en"))
        XCTAssertTrue(DiagnosticScrollMessages.matches("The page keeps changing. Capture paused and segments were kept. Stop animations or wait for loading before continuing.", reason: .changing, language: "en"))
        XCTAssertTrue(DiagnosticScrollMessages.matches("The scroll area is obscured. Capture paused. Move the covering window to continue; captured content was kept.", reason: .obscured, language: "en"))
    }

    func testChineseDiagnosticsRecognizeChineseWarnings() {
        XCTAssertTrue(DiagnosticScrollMessages.matches("选区上方有其他窗口遮挡，无法确认完整可见。请移开遮挡后继续；已有片段会保留。", reason: .visibility, language: "zh-Hans"))
        XCTAssertTrue(DiagnosticScrollMessages.matches("页面持续变化，已暂停。已截片段保留；停止动画或等待加载完成后继续。", reason: .changing, language: "zh-Hans"))
        XCTAssertTrue(DiagnosticScrollMessages.matches("目标滚动区域被遮挡，已暂停。移开遮挡窗口后可继续，已捕获内容保留。", reason: .obscured, language: "zh-Hans"))
    }

    func testWrongLanguageMissingAndUnrelatedWarningsAreRejected() {
        for reason in DiagnosticScrollMessages.Reason.allCases {
            XCTAssertFalse(DiagnosticScrollMessages.matches(reason.fragment(language: "en"), reason: reason, language: "zh-Hans"))
            XCTAssertFalse(DiagnosticScrollMessages.matches(reason.fragment(language: "zh-Hans"), reason: reason, language: "en"))
            for language in ["en", "zh-Hans"] {
                XCTAssertFalse(DiagnosticScrollMessages.matches(nil, reason: reason, language: language))
                XCTAssertFalse(DiagnosticScrollMessages.matches("", reason: reason, language: language))
                XCTAssertFalse(DiagnosticScrollMessages.matches("Recording saved / 录制已保存", reason: reason, language: language))
            }
        }
    }

    func testRuntimeDefaultUsesTheApplicationsResolvedLanguage() {
        for reason in DiagnosticScrollMessages.Reason.allCases {
            XCTAssertTrue(DiagnosticScrollMessages.matches(reason.fragment(language: L10n.language), reason: reason))
        }
    }
}
