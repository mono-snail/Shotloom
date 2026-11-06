import XCTest
@testable import DeskCapture

final class WorkflowMetricsTests: XCTestCase {
    func testPercentilesRejectInvalidInputsAndUseNearestRank() {
        XCTAssertNil(WorkflowMetrics.percentile([], fraction: 0.95))
        XCTAssertNil(WorkflowMetrics.percentile([.nan], fraction: 0.5))
        XCTAssertNil(WorkflowMetrics.percentile([-1], fraction: 0.5))
        XCTAssertNil(WorkflowMetrics.percentile([1], fraction: 2))
        XCTAssertEqual(WorkflowMetrics.percentile([4, 1, 3, 2], fraction: 0.5), 2)
        XCTAssertEqual(WorkflowMetrics.percentile([4, 1, 3, 2], fraction: 0.95), 4)
    }
    func testCERCountsInsertionsDeletionsSubstitutionsAndUnicode() {
        XCTAssertEqual(WorkflowMetrics.characterErrorRate(expected: "截图ABC", actual: "截图ABC"), 0)
        XCTAssertEqual(WorkflowMetrics.characterErrorRate(expected: "截图ABC", actual: "截图AXC"), 0.2)
        XCTAssertEqual(WorkflowMetrics.characterErrorRate(expected: "abc", actual: "ab"), 1.0 / 3)
        XCTAssertEqual(WorkflowMetrics.characterErrorRate(expected: "abc", actual: "abcd"), 1.0 / 3)
        XCTAssertEqual(WorkflowMetrics.characterErrorRate(expected: "", actual: "ab"), 2)
        XCTAssertEqual(WorkflowMetrics.characterErrorRate(expected: "A B\nC", actual: "ABC", ignoringWhitespace: true), 0)
        XCTAssertGreaterThan(WorkflowMetrics.characterErrorRate(expected: "A B\nC", actual: "ABC"), 0)
    }
    func testCorpusIsDeterministicAndHoldoutIsDifferent() {
        let a = WorkflowCorpus.texture(width: 40, height: 60, seed: WorkflowCorpus.trainingSeed)
        let b = WorkflowCorpus.texture(width: 40, height: 60, seed: WorkflowCorpus.trainingSeed)
        let holdout = WorkflowCorpus.texture(width: 40, height: 60, seed: WorkflowCorpus.holdoutSeed)
        XCTAssertEqual(a.dataProvider?.data as Data?, b.dataProvider?.data as Data?)
        XCTAssertNotEqual(a.dataProvider?.data as Data?, holdout.dataProvider?.data as Data?)
    }
}
