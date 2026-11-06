import XCTest
import AppKit
import ImageIO
@testable import DeskCapture

final class SensitiveBatchTests: XCTestCase {
    func testMetadataFromImportedJPEGDoesNotEnterSnapshotOrExport() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("private.jpg")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, WorkflowCorpus.texture(width: 100, height: 80, seed: 11), [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE-ORIGINAL-TEXT"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "PRIVATE-OWNER"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let inputSource = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyExifDictionary])
        let originalBytes = try Data(contentsOf: input)
        var pages = try SensitiveBatchIO.importPages([input], into: root.appendingPathComponent("owned"))
        pages[0].scanned = true; pages[0].reviewed = true
        let output = root.appendingPathComponent("export")
        try SensitiveBatchIO.export(pages, to: output)
        for url in [pages[0].snapshot, output.appendingPathComponent("redacted-001.png")] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            try traceChunks(url)
            XCTAssertNil(properties[kCGImagePropertyExifDictionary]); XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
            XCTAssertFalse(try Data(contentsOf: url).range(of: Data("PRIVATE".utf8)) != nil)
        }
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
    }
    private func traceChunks(_ url: URL) throws {
        let data = try Data(contentsOf: url); var offset = 8, names: [String] = []
        while offset + 12 <= data.count {
            let length = data[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
            names.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
            guard length <= data.count - offset - 12 else { break }; offset += length + 12
        }
        print("SENSITIVE_PNG_CHUNKS", names)
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-batch-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func page(in root: URL) throws -> SensitiveBatchPage {
        let url = root.appendingPathComponent("source.png")
        try SensitiveBatchIO.writeCleanPNG(WorkflowCorpus.texture(width: 100, height: 80, seed: 42), to: url)
        var page = SensitiveBatchPage(snapshot: url, width: 100, height: 80)
        page.scanned = true; page.reviewed = true
        page.manualBounds = [CGRect(x: 0.25, y: 0.25, width: 0.4, height: 0.5)]
        return page
    }
    func testExportContainsOnlyFlattenedImagesAndPreservesOriginal() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let page = try page(in: root), original = try Data(contentsOf: page.snapshot)
        let output = root.appendingPathComponent("output")
        try SensitiveBatchIO.export([page], to: output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["redacted-001.png"])
        XCTAssertEqual(try Data(contentsOf: page.snapshot), original)
        let url = output.appendingPathComponent("redacted-001.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        try traceChunks(url)
        XCTAssertNil(properties[kCGImagePropertyExifDictionary]); XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
        let image = try SensitiveBatchIO.read(url)
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 400,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 80))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // The middle lies inside the opaque redaction regardless of bitmap row order.
        for c in 0..<3 { XCTAssertEqual(bytes[40 * 400 + 45 * 4 + c], 0) }
        XCTAssertEqual(bytes[40 * 400 + 45 * 4 + 3], 255)
    }
    func testLateFailureRollsBackWholeBatchAndExistingDestinationIsUntouched() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try page(in: root)
        var missing = SensitiveBatchPage(snapshot: root.appendingPathComponent("missing.png"), width: 100, height: 80)
        missing.scanned = true; missing.reviewed = true
        let output = root.appendingPathComponent("output")
        XCTAssertThrowsError(try SensitiveBatchIO.export([first, missing], to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".DeskCapture") })
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try SensitiveBatchIO.export([first], to: output))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testCancellationBeforeCommitLeavesNoExport() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let page = try page(in: root), output = root.appendingPathComponent("output")
        let ready = expectation(description: "Encoded stage ready")
        let gate = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try SensitiveBatchIO.export([page], to: output, beforeCommit: {
                ready.fulfill()
                guard gate.wait(timeout: .now() + 5) == .success else { throw CaptureError.message("Test gate timed out") }
            })
        }
        await fulfillment(of: [ready], timeout: 5)
        worker.cancel(); gate.signal()
        do { try await worker.value; XCTFail("Cancelled batch committed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.png"])
    }
    func testUnreviewedPageAndInvalidBoundsAreRejected() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var page = try page(in: root); page.reviewed = false
        XCTAssertThrowsError(try SensitiveBatchIO.export([page], to: root.appendingPathComponent("out")))
        XCTAssertThrowsError(try SensitiveBatchIO.flattened(WorkflowCorpus.texture(width: 40, height: 30, seed: 1), bounds: [.init(x: CGFloat.nan, y: 0, width: 1, height: 1)]))
    }
    func testImportFailureRemovesOnlyOwnedSnapshots() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let page = try page(in: root), original = try Data(contentsOf: page.snapshot)
        let owned = root.appendingPathComponent("snapshots")
        XCTAssertThrowsError(try SensitiveBatchIO.importPages([page.snapshot, root.appendingPathComponent("missing.png")], into: owned))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: page.snapshot), original)
    }
}
