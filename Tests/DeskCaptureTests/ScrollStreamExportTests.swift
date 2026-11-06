import XCTest
import AppKit
@testable import DeskCapture

final class ScrollStreamExportTests: XCTestCase {
    @MainActor
    func testWholeImageCapacityAndVisibleExportRouteAgreeAtBothLimits() {
        for (width, height, whole) in [(4000, 20000, true), (4000, 20001, false), (1, 60000, true),
                                      (1, 60001, false), (60001, 1, false), (Int.max, 2, false)] {
            let plan = ScrollExportPlan(width: width, height: height, axis: .vertical, pieces: [])
            let model = ScrollCapture(preview: ScrollPreview(width: width, height: height))
            XCTAssertEqual(plan.canRenderWhole, whole)
            XCTAssertEqual(model.requiresStreamingExport, !whole)
        }
        XCTAssertFalse(ScrollCapture().requiresStreamingExport)
        XCTAssertFalse(ScrollImageCapacity.canRenderWhole(width: 0, height: 100))
        XCTAssertFalse(ScrollImageCapacity.canRenderWhole(width: 100, height: -1))
    }

    func testRowGeneratorMatchesIndependentOriginalPage() throws {
        let page = WorkflowCorpus.texture(width: 100, height: 300, seed: 42)
        let expected = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 70, width: 100, height: 100)))
        XCTAssertEqual(try pixels(WorkflowCorpus.textureRows(width: 100, start: 70, height: 100)), try pixels(expected))
    }
    @MainActor
    func testModelCancellationKeepsOldDirectoryAndSession() async throws {
        let modelSource = try await Task.detached {
            let source = try ScrollStitcher(detectsFixedEdges: false)
            try source.append(WorkflowCorpus.texture(width: 2000, height: 2000, seed: 42))
            return source
        }.value
        let model = ScrollCapture(stitcher: modelSource)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("keep.txt"); try Data("original".utf8).write(to: sentinel)
        var completions = 0
        model.onStreamExport = { _ in completions += 1 }
        let saving = Task { await model.finish(output: .segments(root)) }
        for _ in 0..<100 where !model.finishing { await Task.yield() }
        await model.cancel(); await saving.value
        XCTAssertTrue(model.active); XCTAssertTrue(model.paused); XCTAssertFalse(model.finishing)
        XCTAssertEqual(model.frames, 1); XCTAssertEqual(completions, 0)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
        await model.cancel()
    }
    func testCaptureBeyondSixtyThousandPixelsExportsExactChunks() throws {
        let page = WorkflowCorpus.texture(width: 160, height: 68000, seed: 42)
        let model = try ScrollStitcher(detectsFixedEdges: false)
        for start in stride(from: 0, through: 65700, by: 730) {
            XCTAssertEqual(try model.append(XCTUnwrap(page.cropping(to: CGRect(x: 0, y: start, width: 160, height: 1000)))), start == 0 ? 1000 : 730)
        }
        XCTAssertGreaterThan(model.preview.height, 60000)
        XCTAssertThrowsError(try model.render())
        let plan = try model.exportPlan()
        for region in try plan.regions(edge: 4096) {
            let expected = try XCTUnwrap(page.cropping(to: region))
            XCTAssertEqual(try pixels(plan.render(region)), try pixels(expected))
        }
        let folder = model.directory.appendingPathComponent("export")
        try plan.exportSegments(to: folder)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["height"] as? Int, 66700)
        XCTAssertEqual((manifest?["parts"] as? [[String: Any]])?.count, 17)
        try model.removeLast()
        XCTAssertEqual(try model.exportPlan().height, 65970)
    }
    func testHorizontalCaptureBeyondSixtyThousandPixelsInBothDirections() throws {
        let page = WorkflowCorpus.texture(width: 68000, height: 160, seed: 42)
        for direction in ScrollDirection.allCases {
            let model = try ScrollStitcher(axis: .horizontal, direction: direction, detectsFixedEdges: false)
            let offsets = Array(stride(from: 0, through: 65700, by: 730))
            for start in direction == .forward ? offsets : offsets.reversed() {
                XCTAssertEqual(try model.append(XCTUnwrap(page.cropping(to: CGRect(x: start, y: 0, width: 1000, height: 160)))), model.frameCount == 1 ? 1000 : 730)
            }
            let plan = try model.exportPlan()
            XCTAssertEqual(plan.width, 66700); XCTAssertFalse(plan.canRenderWhole)
            for region in try plan.regions() {
                XCTAssertEqual(try pixels(plan.render(region)), try pixels(XCTUnwrap(page.cropping(to: region))))
            }
            let pdf = model.directory.appendingPathComponent("horizontal.pdf")
            try plan.exportPDF(to: pdf)
            let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
            XCTAssertGreaterThan(document.numberOfPages, 1)
            XCTAssertGreaterThan(try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox).width, 595)
        }
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }
    func testStreamingPiecesMatchOriginalPixelsAcrossAxesDirectionsAndUndo() throws {
        for axis in [ScrollAxis.vertical, .horizontal] {
            for direction in ScrollDirection.allCases {
                let vertical = axis == .vertical
                let page = WorkflowCorpus.texture(width: vertical ? 400 : 1500, height: vertical ? 1500 : 400, seed: 42)
                let model = try ScrollStitcher(axis: axis, direction: direction)
                let starts = direction == .forward ? [100, 213, 340] : [500, 387, 260]
                for start in starts {
                    try model.append(try XCTUnwrap(page.cropping(to: vertical ? CGRect(x: 0, y: start, width: 400, height: 600) : CGRect(x: start, y: 0, width: 600, height: 400))))
                }
                let plan = try model.exportPlan()
                for region in try plan.regions(edge: 256) {
                    let expected = try XCTUnwrap(page.cropping(to: region.offsetBy(dx: vertical ? 0 : CGFloat(starts.min()!), dy: vertical ? CGFloat(starts.min()!) : 0)))
                    XCTAssertEqual(try pixels(plan.render(region)), try pixels(expected))
                }
                try model.removeLast()
                let whole = try model.render(), revised = try model.exportPlan()
                XCTAssertEqual(try pixels(revised.render(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))), try pixels(whole))
            }
        }
    }
    func testFailedAndCancelledBundleOrPDFPreservesExistingDestination() throws {
        let model = try ScrollStitcher(); try model.append(WorkflowCorpus.texture(width: 400, height: 600, seed: 42))
        let plan = try model.exportPlan(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let sentinel = bundle.appendingPathComponent("sentinel.txt"); try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try plan.exportSegments(to: bundle, edge: 256, beforePart: { if $0 == 1 { throw CancellationError() } }))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        let pdf = root.appendingPathComponent("existing.pdf"); try Data("keep-pdf".utf8).write(to: pdf)
        XCTAssertThrowsError(try plan.exportPDF(to: pdf, beforePage: { _ in throw CancellationError() }))
        XCTAssertEqual(try String(contentsOf: pdf, encoding: .utf8), "keep-pdf")
        let missing = ScrollExportPlan(width: plan.width, height: plan.height, axis: plan.axis,
                                      pieces: plan.pieces.map { ScrollRenderPiece(url: root.appendingPathComponent("missing.png"), crop: $0.crop, destination: $0.destination) })
        XCTAssertThrowsError(try missing.exportSegments(to: bundle))
        XCTAssertThrowsError(try missing.exportPDF(to: pdf))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: pdf, encoding: .utf8), "keep-pdf")
        XCTAssertThrowsError(try plan.exportSegments(to: pdf))
        XCTAssertThrowsError(try plan.exportPDF(to: bundle))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: pdf, encoding: .utf8), "keep-pdf")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".DeskCapture-") })
        XCTAssertEqual(model.frameCount, 1)
        try plan.exportSegments(to: bundle, edge: 256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("manifest.json").path))
        try plan.exportPDF(to: pdf)
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL)); XCTAssertGreaterThan(document.numberOfPages, 0)
    }
    func testPlanBeyondBothOldLimitsUsesBoundedRegions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = WorkflowCorpus.texture(width: 4000, height: 1000, seed: 42), url = root.appendingPathComponent("source.png")
        try CaptureImageExport.png(source, to: url)
        let pieces = (0..<22).map { ScrollRenderPiece(url: url, crop: CGRect(x: 0, y: 0, width: 4000, height: 1000), destination: CGRect(x: 0, y: $0 * 1000, width: 4000, height: 1000)) }
        let plan = ScrollExportPlan(width: 4000, height: 22000, axis: .vertical, pieces: pieces)
        XCTAssertFalse(plan.canRenderWhole)
        for rect in try plan.regions(edge: 1024) { XCTAssertLessThanOrEqual(rect.width * rect.height, 1024 * 1024) }
        let bottom = try plan.render(CGRect(x: 200, y: 21300, width: 600, height: 400))
        XCTAssertEqual(try pixels(bottom), try pixels(XCTUnwrap(source.cropping(to: CGRect(x: 200, y: 300, width: 600, height: 400)))))
        let tall = ScrollExportPlan(width: 100, height: 65001, axis: .vertical, pieces: [])
        XCTAssertFalse(tall.canRenderWhole)
        XCTAssertEqual(try tall.regions().last?.maxY, 65001)
    }
    func testPDFCancellationAndReadFailureAfterFirstPagePreserveOldFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try CaptureImageExport.png(WorkflowCorpus.texture(width: 600, height: 1000, seed: 42), to: source)
        let pieces = (0..<3).map { ScrollRenderPiece(url: source, crop: CGRect(x: 0, y: 0, width: 600, height: 1000), destination: CGRect(x: 0, y: $0 * 1000, width: 600, height: 1000)) }
        let plan = ScrollExportPlan(width: 600, height: 3000, axis: .vertical, pieces: pieces)
        let destination = root.appendingPathComponent("old.pdf"), original = Data("keep-original-pdf".utf8)
        try original.write(to: destination)
        var cancelledAt = -1
        XCTAssertThrowsError(try plan.exportPDF(to: destination, beforePage: { page in
            if page == 1 { cancelledAt = page; throw CancellationError() }
        }))
        XCTAssertEqual(cancelledAt, 1); XCTAssertEqual(try Data(contentsOf: destination), original)
        let broken = ScrollExportPlan(width: 600, height: 3000, axis: .vertical, pieces: pieces.enumerated().map { index, piece in
            ScrollRenderPiece(url: index == 0 ? source : root.appendingPathComponent("missing.png"), crop: piece.crop, destination: piece.destination)
        })
        var lastPage = -1
        XCTAssertThrowsError(try broken.exportPDF(to: destination, beforePage: { lastPage = $0 }))
        XCTAssertEqual(lastPage, 1); XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".DeskCapture-pages-") })
    }
}
