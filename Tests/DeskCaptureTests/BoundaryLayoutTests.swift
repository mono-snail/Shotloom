import XCTest
@testable import DeskCapture

final class BoundaryLayoutTests: XCTestCase {
    @MainActor func testLateLayoutRejectsEditsSelectionChangesAndCancellation() async throws {
        for mode in 0..<3 {
            let document = AnnotationDocument(image: WorkflowCorpus.texture(width: 200, height: 160, seed: 2))
            document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)]))
            document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.5, y: 0.4), .init(x: 0.6, y: 0.5)]))
            document.selectAllMarks()
            let previous = document.marks.map(\.points)
            document.beforeArrangementCommitForDiagnostics = {
                if mode == 0 { document.add(document.makeMark(tool: .line, points: [.zero, .init(x: 1, y: 1)])) }
                else if mode == 1 { document.selectMark(at: .init(x: 0.15, y: 0.15), tolerance: .zero) }
                else { document.cancelArrangement() }
            }
            await document.arrangeSelected(.left)
            XCTAssertEqual(Array(document.marks.prefix(2)).map(\.points), previous)
            XCTAssertFalse(document.arrangingMarks)
            if mode != 2 { XCTAssertNotNil(document.arrangementError) }
            document.beforeArrangementCommitForDiagnostics = nil
        }
    }
    func testLowConfidenceDoesNotSnapAndSmallestCandidateWins() {
        let outer = ContentBoundary(bounds: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8), confidence: 1, text: false)
        let inner = ContentBoundary(bounds: .init(x: 0.2, y: 0.2, width: 0.2, height: 0.1), confidence: 0.9, text: true)
        let low = ContentBoundary(bounds: .init(x: 0.22, y: 0.22, width: 0.01, height: 0.01), confidence: 0.4, text: true)
        XCTAssertEqual(ContentBoundaryEngine.hit(.init(x: 0.225, y: 0.225), candidates: [outer, inner, low])?.id, inner.id)
        let selected = CGRect(x: 0.21, y: 0.21, width: 0.18, height: 0.08)
        XCTAssertEqual(ContentBoundaryEngine.snap(selected, candidates: [low], tolerance: .init(width: 0.03, height: 0.03)), selected)
        let snapped = ContentBoundaryEngine.snap(selected, candidates: [inner], tolerance: .init(width: 0.02, height: 0.02))
        XCTAssertEqual(snapped.minX, 0.2, accuracy: 0.00001); XCTAssertEqual(snapped.maxY, 0.3, accuracy: 0.00001)
    }
    func testPixelLogicalDimensionsUseRecordedScale() throws {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.25)
        for scale in [CGFloat(1), 1.5, 2, 3] {
            let size = try ContentBoundaryEngine.dimensions(box, pixels: CGSize(width: 1600, height: 1200), scale: scale)
            XCTAssertEqual(size.pixels, CGSize(width: 800, height: 300))
            XCTAssertEqual(size.logical.width, 800 / scale, accuracy: 0.00001)
        }
        XCTAssertThrowsError(try ContentBoundaryEngine.dimensions(box, pixels: .init(width: 100, height: 100), scale: .nan))
    }
    func testDistributionUsesEqualGapsWithUnequalObjectWidths() {
        let boxes = [CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), CGRect(x: 0.35, y: 0.2, width: 0.2, height: 0.1), CGRect(x: 0.8, y: 0.3, width: 0.1, height: 0.1)]
        let deltas = AnnotationLayout.translations(boxes, operation: .horizontalGaps)
        let result = zip(boxes, deltas).map { $0.offsetBy(dx: $1.x, dy: $1.y) }
        XCTAssertEqual(result[0].minX, boxes[0].minX, accuracy: 0.00001)
        XCTAssertEqual(result[2].maxX, boxes[2].maxX, accuracy: 0.00001)
        XCTAssertEqual(result[1].minX - result[0].maxX, result[2].minX - result[1].maxX, accuracy: 0.00001)
        let top = AnnotationLayout.translations(boxes, operation: .top)
        for (box, delta) in zip(boxes, top) { XCTAssertEqual(box.maxY + delta.y, 0.4, accuracy: 0.00001) }
    }
    func testSnapToleranceScalesWithViewportAndKeyboardCanStayExact() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), delta = CGPoint(x: 0.194, y: 0)
        let at1000 = AnnotationLayout.snapped(delta, group: box, targets: [], tolerance: CGSize(width: CGFloat(6) / 1000, height: CGFloat(6) / 1000))
        let at2000 = AnnotationLayout.snapped(delta, group: box, targets: [], tolerance: CGSize(width: CGFloat(6) / 2000, height: CGFloat(6) / 2000))
        XCTAssertEqual(at1000.x, 0.2, accuracy: 0.00001); XCTAssertEqual(at2000.x, delta.x, accuracy: 0.00001)
    }
    @MainActor func testArrangeIsOneUndoAndLeavesUnselectedMarkUnchanged() async throws {
        let document = AnnotationDocument(image: WorkflowCorpus.texture(width: 400, height: 300, seed: 1))
        document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)]))
        document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.4, y: 0.3), .init(x: 0.5, y: 0.4)]))
        let chosen = document.marks
        document.selectAllMarks()
        document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.7, y: 0.6), .init(x: 0.9, y: 0.8)]))
        // add clears selection, so select the intended two through the real selection API.
        document.selectMark(at: .init(x: 0.15, y: 0.15), tolerance: .zero)
        document.selectMark(at: .init(x: 0.45, y: 0.35), tolerance: .zero, additive: true)
        let previous = document.marks
        await document.arrangeSelected(.left)
        XCTAssertEqual(document.marks[1].points[0].x, 0.1, accuracy: 0.00001)
        XCTAssertEqual(document.marks[2].points, previous[2].points)
        document.undo()
        XCTAssertEqual(document.marks.map(\.points), previous.map(\.points))
        XCTAssertEqual(chosen.count, 2)
    }
}
