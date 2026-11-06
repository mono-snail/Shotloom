import XCTest
@testable import DeskCapture

final class SensitiveRuleTests: XCTestCase {
    private func line(_ text: String, alternatives: [String] = []) -> OCRLine {
        OCRLine(text: text, bounds: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.1), confidence: 1, alternatives: alternatives)
    }
    func testRestrictedPatternsRejectExpensiveOrUnsupportedSyntax() throws {
        for pattern in ["(a+)+", "a|b", "a*", "a+", "a?", #"\1"#, "a{0,3}", "a{65}", "a{1,4}b{1,4}", "a{", "[abc", "^$"] {
            XCTAssertThrowsError(try SafeSensitivePattern.cost(pattern), pattern)
        }
        XCTAssertGreaterThan(try SafeSensitivePattern.cost(#"^INV-[A-Z0-9]{4,12}$"#), 0)
    }
    func testScopesCasePrefixAndDisagreementCandidates() throws {
        let orders = SensitiveRule(title: "订单", pattern: "ORDER-", mode: .prefix, scope: .images)
        let captions = SensitiveRule(title: "字幕限定", pattern: "SECRET", scope: .captions)
        let exact = SensitiveRule(title: "大小写", pattern: "Token", caseSensitive: true)
        let lines = [line("order-123"), line("reference order-123"), line("SECRET"), line("token"), line("Token"), line("识别分歧", alternatives: ["ORDER-999"])]
        let result = try SensitiveRuleEvaluation.classify(lines, kinds: [], rules: [orders, captions, exact], scope: .images)
        XCTAssertEqual(result.map(\.line.text), ["order-123", "Token", "识别分歧"])
        XCTAssertEqual(result.last?.ruleNames, ["订单"])
        let builtin = try SensitiveRuleEvaluation.classify([line("候选", alternatives: ["test@example.com"])], kinds: [.email], rules: [], scope: .images)
        XCTAssertEqual(builtin.first?.kinds, [.email])
    }
    func testBudgetsFailInsteadOfReturningPartialCleanResult() throws {
        XCTAssertThrowsError(try SensitiveRuleEvaluation.classify([line(String(repeating: "a", count: 4097))], kinds: [], rules: [], scope: .images))
        XCTAssertThrowsError(try SensitiveRuleEvaluation.classify((0..<5001).map { _ in line("x") }, kinds: [], rules: [], scope: .images))
        let expensive = SensitiveRule(pattern: ".{1,64}" + String(repeating: "a", count: 200), mode: .boundedPattern)
        XCTAssertThrowsError(try SensitiveRuleEvaluation.classify([line(String(repeating: "a", count: 4096))], kinds: [], rules: [expensive], scope: .images))
        var duplicate = SensitiveRule(); duplicate.enabled = false
        XCTAssertThrowsError(try SensitiveRuleEvaluation.validate([duplicate, duplicate]))
    }
    @MainActor func testIsolatedPreferencesRoundTripAndInvalidSavePreservesPrevious() async throws {
        let suite = "DeskCapture.SensitiveRules.Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SensitiveRuleStore(defaults: defaults)
        let expected = [SensitiveRule(title: "客户编号", pattern: "客户编号")]
        try await store.save(expected)
        let revision = store.revision
        var invalid = expected[0]; invalid.mode = .boundedPattern; invalid.pattern = "(a+)+"
        do { try await store.save([invalid]); XCTFail("Invalid rule accepted") } catch { }
        XCTAssertEqual(store.rules, expected); XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(SensitiveRuleStore(defaults: defaults).rules, expected)
        defaults.set(Data("broken".utf8), forKey: "sensitiveCustomRules.v1")
        XCTAssertNotNil(SensitiveRuleStore(defaults: defaults).loadError)
        XCTAssertEqual(defaults.data(forKey: "sensitiveCustomRules.v1"), Data("broken".utf8))
    }
}
