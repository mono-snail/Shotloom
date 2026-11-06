import XCTest
import AppKit
import CoreText
@testable import DeskCapture

final class OCRTableReviewTests: XCTestCase {
    private func cells() -> [OCRTableCell] {
        [.init(row: 0, column: 0, rowSpan: 2, columnSpan: 2, text: "<script>alert('x') & more</script>\nline\t2"),
         .init(row: 0, column: 2, rowSpan: 1, columnSpan: 1, text: "Tail"),
         .init(row: 1, column: 2, rowSpan: 1, columnSpan: 1, text: "Next")]
    }
    func testHTMLPreservesBothSpansEscapesTextAndJSONRetainsUnflattenedValues() throws {
        let output = try OCRTableExport.prepare(cells()), html = try XCTUnwrap(String(data: output.html, encoding: .utf8))
        XCTAssertTrue(html.contains("rowspan=\"2\" colspan=\"2\""))
        XCTAssertFalse(html.contains("<script>")); XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&#39;x&#39;")); XCTAssertTrue(html.contains("&amp; more")); XCTAssertTrue(html.contains("<br>line"))
        XCTAssertEqual(html.components(separatedBy: "<td ").count - 1, 3)
        XCTAssertEqual(output.table.rows.count, 2); XCTAssertEqual(output.table.rows.first?.count, 3)
        XCTAssertEqual(output.table.rows[1], ["", "", "Next"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output.json) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1); XCTAssertEqual(json["indexBase"] as? Int, 0)
        let records = try XCTUnwrap(json["cells"] as? [[String: Any]])
        XCTAssertEqual(records.first?["text"] as? String, cells()[0].text)
        XCTAssertEqual(records.first?["rowSpan"] as? Int, 2)
        XCTAssertEqual(output.tsvData, Data(output.tsv.utf8))
        XCTAssertNil(json["sourceImage"])
    }
    func testBlankHolesAreEmittedAndOverlappingRangesRefuseEveryOutput() throws {
        let sparse = try OCRTableExport.prepare([.init(row: 0, column: 0, rowSpan: 1, columnSpan: 1, text: "A"),
                                                .init(row: 1, column: 1, rowSpan: 1, columnSpan: 1, text: "B")])
        XCTAssertEqual(sparse.tsv, "A\t\n\tB")
        XCTAssertEqual(String(decoding: sparse.html, as: UTF8.self).components(separatedBy: "<td></td>").count - 1, 2)
        var overlapping = cells(); overlapping[1].column = 1
        XCTAssertThrowsError(try OCRTableExport.prepare(overlapping))
    }
    func testCancelledAndFailedExportsPreserveExistingDestinationAndCleanOwnStage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("table-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("table.html"), original = Data("old destination".utf8)
        try original.write(to: file)
        let output = try OCRTableExport.prepare(cells())
        XCTAssertThrowsError(try OCRTableExport.write(output.html, to: file, beforeCommit: { throw CaptureError.message("injected write failure") }))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let worker = Task.detached {
            try OCRTableExport.write(output.html, to: file, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { try await worker.value; XCTFail("Cancelled table write committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["table.html"])
        try OCRTableExport.write(output.html, to: file)
        XCTAssertEqual(try Data(contentsOf: file), output.html)
    }
    @MainActor
    func testEditedOverlapClearsDeliveryUntilRepairedAndCloseRejectsLateOutput() async throws {
        let model = OCRTableReviewModel(try OCRTableResult.assemble(cells()))
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.output)
        model.update(1, \.column, 1)
        XCTAssertNil(model.output)
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(model.output); XCTAssertNotNil(model.error)
        model.update(1, \.column, 2)
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.output)
        model.update(1, \.text, "edited"); model.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.output); XCTAssertFalse(model.busy)
    }
    @MainActor
    func testNamedPasteboardReceivesHTMLAndPlainTSVWithoutOriginalImage() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("table-copy-\(UUID())")
        let board = NSPasteboard(name: .init("table-copy-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let app = AppCoordinator(store: CaptureStore(directory: root, pruneOnInit: false), imagePasteboard: board, registerHotKeys: false)
        let output = try OCRTableExport.prepare(cells())
        app.copyReviewedTable(output)
        XCTAssertEqual(board.data(forType: .html), output.html)
        XCTAssertEqual(board.string(forType: .string), output.tsv)
        XCTAssertNil(board.data(forType: .png)); XCTAssertTrue(app.store.records.isEmpty)
    }
    @MainActor
    func testRealVisionMergedHeaderSurvivesStructuredExport() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Document table recognition requires macOS 26+") }
        let image = try await Task.detached { try Self.mergedFixture() }.value
        let table = try await CaptureEngine.extractTable(image)
        XCTAssertTrue(table.requiresReview, "Native merged cells or uncovered heading text must require visible review")
        let model = OCRTableReviewModel(table)
        if !table.cells.contains(where: { $0.text.contains("Quarterly") }) {
            let heading = try XCTUnwrap(model.pendingLines.first { $0.text.contains("Quarterly") }, "Vision's omitted heading must remain available for explicit correction")
            model.includeLine(heading.id, atTop: true)
        }
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        let output = try XCTUnwrap(model.output)
        let title = try XCTUnwrap(output.table.cells.first { $0.text.contains("Quarterly") })
        XCTAssertEqual(title.columnSpan, 3)
        XCTAssertTrue(String(decoding: output.html, as: UTF8.self).contains("colspan=\"3\""))
        XCTAssertNotNil(title.bounds)
    }
    @MainActor
    func testUnassignedHeadingBlocksDeliveryUntilExplicitlyAddedOrIgnored() async throws {
        let cells: [OCRTableCell] = [
            .init(row: 0, column: 0, rowSpan: 1, columnSpan: 1, text: "Item", bounds: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.1)),
            .init(row: 0, column: 1, rowSpan: 1, columnSpan: 1, text: "12", bounds: CGRect(x: 0.6, y: 0.4, width: 0.1, height: 0.1))]
        let lines = [OCRLine(text: "Report", bounds: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.1), confidence: 1),
                     OCRLine(text: "Item 12", bounds: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.1), confidence: 1)]
        let unassigned = try OCRTableCoverage.unassigned(lines, cells: cells)
        XCTAssertEqual(unassigned.map(\.text), ["Report"])
        let table = try OCRTableResult.assemble(cells, unassignedLines: unassigned)
        XCTAssertTrue(table.requiresReview); XCTAssertFalse(table.hasMergedCells)
        let model = OCRTableReviewModel(table)
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unreviewed-table-\(UUID()).html")
        model.save(to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        model.includeLine(unassigned[0].id, atTop: true)
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.pendingLines.isEmpty)
        XCTAssertEqual(model.output?.tsv, "Report\t\nItem\t12")
        XCTAssertEqual(model.cells.first?.row, 1)
        let ignored = OCRTableReviewModel(table)
        ignored.ignoreLine(unassigned[0].id)
        XCTAssertTrue(ignored.pendingLines.isEmpty); XCTAssertEqual(ignored.cells, cells)
    }

    private static func mergedFixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1040, height: 480, bitsPerComponent: 8, bytesPerRow: 4160,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1040, height: 480))
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 30, nil),
            .init(kCTForegroundColorAttributeName as String): NSColor.black.cgColor]
        let rows = [["Quarterly report"], ["Item", "Units", "Value"], ["Alpha", "12", "3.50"], ["Beta", "7", "2.80"]]
        for (row, values) in rows.enumerated() {
            for (column, text) in values.enumerated() {
                context.textPosition = CGPoint(x: 56 + column * 320, y: 390 - row * 90)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            }
        }
        context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(2)
        for y in [70, 160, 250, 340, 430] { context.move(to: CGPoint(x: 40, y: y)); context.addLine(to: CGPoint(x: 1000, y: y)) }
        for x in [40, 1000] { context.move(to: CGPoint(x: x, y: 70)); context.addLine(to: CGPoint(x: x, y: 430)) }
        for x in [360, 680] { context.move(to: CGPoint(x: x, y: 70)); context.addLine(to: CGPoint(x: x, y: 340)) }
        context.strokePath()
        return try XCTUnwrap(context.makeImage())
    }
}
