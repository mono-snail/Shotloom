import XCTest
@testable import DeskCapture

final class OCRStructuredTests: XCTestCase {
    func testMergedCellsKeepAnchorAndTrailingEmptyColumns() throws {
        let table = try OCRTableResult.assemble([
            .init(row: 0, column: 0, rowSpan: 1, columnSpan: 2, text: "Header"),
            .init(row: 1, column: 0, rowSpan: 1, columnSpan: 1, text: "A\tB\r\nC"),
            .init(row: 1, column: 1, rowSpan: 1, columnSpan: 1, text: "")])
        XCTAssertTrue(table.hasMergedCells)
        XCTAssertEqual(table.tsv, "Header\t\nA B C\t")
        XCTAssertThrowsError(try OCRTableResult.assemble([
            .init(row: 0, column: 0, rowSpan: 1, columnSpan: 2, text: "H"),
            .init(row: 0, column: 1, rowSpan: 1, columnSpan: 1, text: "overlap")]))
        XCTAssertThrowsError(try OCRTableResult.assemble([.init(row: Int.max, column: 0, rowSpan: 1, columnSpan: 1, text: "bad")]))
    }
    func testFragmentedCodePreservesRowsAndMeasuredIndentation() {
        let fragments = [
            OCRCodeFragment(text: "return", bounds: CGRect(x: 0.14, y: 0.5, width: 0.06, height: 0.03), characterAdvance: 0.01),
            OCRCodeFragment(text: "x + 1", bounds: CGRect(x: 0.21, y: 0.501, width: 0.05, height: 0.03), characterAdvance: nil),
            OCRCodeFragment(text: "func f() {", bounds: CGRect(x: 0.1, y: 0.7, width: 0.11, height: 0.03), characterAdvance: 0.01),
            OCRCodeFragment(text: "}", bounds: CGRect(x: 0.1, y: 0.3, width: 0.005, height: 0.03), characterAdvance: nil)]
        XCTAssertEqual(OCRCodeLayout.format(fragments), "func f() {\n    return x + 1\n}")
    }
    @available(macOS 26.0, *)
    func testActualTableRecoversVisibleDigitAndPreservesTrueBlank() async throws {
        for value in ["7", ""] {
            let sample = OCRReferenceCorpus.Sample(id: "test", category: "table", fontSize: 18,
                lines: ["Item\tCount\tPrice", "Apple\t12\t3.50", "Pear\t\(value)\t2.80"])
            let image = try OCRReferenceCorpus.render(sample)
            let result = try await CaptureEngine.extractTable(image)
            XCTAssertEqual(result.tsv, sample.expected)
        }
    }
    func testActualCodeIndentationAcrossReferenceSizes() async throws {
        for sample in OCRReferenceCorpus.samples where sample.category == "code" {
            let image = try OCRReferenceCorpus.render(sample)
            let code = try await CaptureEngine.extract(image, destination: .code)
            XCTAssertTrue(code.contains("\n    return values.reduce(0, +)"), "\(sample.id): \(code)")
        }
    }
}
