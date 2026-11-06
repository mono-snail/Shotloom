import XCTest
import AppKit
@testable import DeskCapture

final class UISimplificationTests: XCTestCase {
    func testMovingContainerMovesDescendantsAndPreservesUnrelatedObjects() throws {
        let blocks = try UISimplification.inferred(text: [CGRect(x: 0.25, y: 0.25, width: 0.1, height: 0.05),
                                                        CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.05)],
                                                    controls: [CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)])
        let result = try UISimplification.editing(blocks, id: blocks[0].id) { $0.bounds.origin.x += 0.1 }
        XCTAssertEqual(result[1].bounds.minX, 0.35, accuracy: 0.000001)
        XCTAssertEqual(result[1].sourceBounds, blocks[1].sourceBounds)
        XCTAssertEqual(result[2], blocks[2])
        XCTAssertThrowsError(try UISimplification.editing(blocks, id: blocks[0].id) { $0.bounds.origin.x = 0.9 })
    }
    func testInferencePreservesPositionsAndSmallestContainingParent() throws {
        let outer = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let inner = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let text = CGRect(x: 0.25, y: 0.4, width: 0.3, height: 0.05)
        let blocks = try UISimplification.inferred(text: [text], controls: [outer, inner])
        XCTAssertEqual(blocks.map(\.bounds), [outer, inner, text])
        XCTAssertEqual(blocks[1].parent, blocks[0].id)
        XCTAssertEqual(blocks[2].parent, blocks[1].id)
        XCTAssertEqual(blocks[2].sourceBounds, text)
    }
    func testEditableProjectRetainsSourceAndLayout() throws {
        let source = WorkflowCorpus.texture(width: 80, height: 60, seed: 123)
        var blocks = try UISimplification.inferred(text: [.init(x: 0.1, y: 0.2, width: 0.4, height: 0.1)], controls: [])
        blocks[0].label = "教程示意"; blocks[0].darkStyle = true; blocks[0].bounds.origin.y = 0.6
        let data = try UISimplification.project(source: source, blocks: blocks)
        let (restored, layout) = try UISimplification.open(data)
        XCTAssertEqual(restored.width, source.width); XCTAssertEqual(restored.height, source.height)
        XCTAssertEqual(layout, blocks)
        XCTAssertEqual(try UISimplification.render(source: restored, blocks: layout).width, 80)
    }
    func testInvalidCoordinatesAndHierarchyCyclesAreRejected() throws {
        var a = SimplifiedBlock(kind: .control, bounds: .init(x: 0, y: 0, width: 1, height: 1))
        var b = SimplifiedBlock(kind: .text, bounds: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        a.parent = b.id; b.parent = a.id
        XCTAssertThrowsError(try UISimplification.validate([a, b]))
        a.parent = nil; b.parent = nil; b.bounds.origin.x = .nan
        XCTAssertThrowsError(try UISimplification.validate([a, b]))
        b.bounds.origin.x = 0.9
        XCTAssertThrowsError(try UISimplification.validate([a, b]))
        XCTAssertThrowsError(try UISimplification.open(Data("not a project".utf8)))
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func testRestoringRegionReturnsOriginalVisiblePixels() throws {
        let image = WorkflowCorpus.texture(width: 64, height: 48, seed: 71)
        var block = SimplifiedBlock(kind: .text, bounds: .init(x: 0, y: 0, width: 1, height: 1))
        let original = try rgba(SensitiveBatchIO.flattened(image, bounds: []))
        XCTAssertNotEqual(try rgba(UISimplification.render(source: image, blocks: [block])), original)
        block.restored = true
        XCTAssertEqual(try rgba(UISimplification.render(source: image, blocks: [block])), original)
    }
    func testMovedPlaceholderKeepsOriginalPositionCovered() throws {
        let image = WorkflowCorpus.texture(width: 100, height: 100, seed: 93)
        var blocks = try UISimplification.inferred(text: [.init(x: 0.1, y: 0.1, width: 0.3, height: 0.2)], controls: [])
        blocks[0].bounds.origin.y = 0.6
        let output = try rgba(UISimplification.render(source: image, blocks: blocks))
        let original = try rgba(SensitiveBatchIO.flattened(image, bounds: []))
        // Old and new locations are both changed, whatever the CGContext row order.
        XCTAssertNotEqual(output, original)
        XCTAssertEqual(blocks[0].sourceBounds?.minY, 0.1)
        // Both the old and moved locations are now neutral placeholders; this
        // catches the old text resurfacing when only the new box is painted.
        for y in [25, 75] {
            let offset = (y * 100 + 20) * 4
            XCTAssertLessThanOrEqual(abs(Int(output[offset]) - Int(output[offset + 1])), 1)
            XCTAssertLessThanOrEqual(abs(Int(output[offset + 1]) - Int(output[offset + 2])), 1)
        }
        let first = try rgba(UISimplification.render(source: image, blocks: try UISimplification.inferred(text: [], controls: [])))
        XCTAssertEqual(first, original)
    }
}
