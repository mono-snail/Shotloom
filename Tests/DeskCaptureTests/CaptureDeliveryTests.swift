import XCTest
import AppKit
@testable import DeskCapture

final class CaptureDeliveryTests: XCTestCase {
    func testHistoryReadAndEncodingRunOffMainAndRespectCancellation() async throws {
        let started = expectation(description: "history loading started off main")
        let stopped = expectation(description: "history read cancelled")
        let task = Task {
            try await ClipboardImageEncoding.encode(logicalSize: false, backingScale: 1) {
                defer { stopped.fulfill() }
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline { try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.001) }
                XCTFail("Loading did not receive cancellation")
                return WorkflowCorpus.texture(width: 40, height: 30, seed: 42)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled history read was delivered") }
        catch is CancellationError { }
        await fulfillment(of: [stopped], timeout: 2)
    }

    @MainActor
    func testHistoryCopyUsesFilePipelineAndDoesNotOverwriteLaterWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-history-delivery-\(UUID())")
        let board = NSPasteboard(name: .init("DeskCapture-history-copy-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        let record = try await store.addAsync(WorkflowCorpus.texture(width: 80, height: 60, seed: 42), mode: .region, backingScale: 1)
        var delivered = 0; app.onImageCopyCompleted = { delivered += 1 }
        app.copy(record); await app.waitForPendingImageCopy()
        let data = try XCTUnwrap(board.data(forType: .png))
        let decoder = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        XCTAssertEqual(image.width, 80); XCTAssertEqual(image.height, 60); XCTAssertEqual(delivered, 1)
        app.copy(record)
        board.clearContents(); board.setString("owned later writer", forType: .string)
        await app.waitForPendingImageCopy()
        XCTAssertEqual(board.string(forType: .string), "owned later writer"); XCTAssertEqual(delivered, 1)
        app.copy(record); app.copy(WorkflowCorpus.texture(width: 48, height: 32, seed: 73))
        await app.waitForPendingImageCopy()
        let latest = try XCTUnwrap(board.data(forType: .png))
        let latestSource = try XCTUnwrap(CGImageSourceCreateWithData(latest as CFData, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(latestSource, 0, nil)?.width, 48)
        XCTAssertEqual(delivered, 2)
    }

    @MainActor
    func testMissingHistoryImagePreservesClipboardAndReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-missing-delivery-\(UUID())")
        let board = NSPasteboard(name: .init("DeskCapture-missing-copy-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        board.setString("owned destination", forType: .string)
        let revision = board.changeCount
        let app = AppCoordinator(store: CaptureStore(directory: directory), imagePasteboard: board, registerHotKeys: false)
        let record = CaptureRecord(id: UUID(), createdAt: Date(), filename: "missing-owned.png", width: 80, height: 60, mode: CaptureMode.region.rawValue)
        app.copy(record); await app.waitForPendingImageCopy()
        XCTAssertEqual(board.string(forType: .string), "owned destination")
        XCTAssertEqual(board.changeCount, revision)
        XCTAssertTrue(app.notice?.hasPrefix(L10n.text("复制失败：\("")")) == true)
    }

    @MainActor
    func testDeletedHistoryRecordCannotOpenALateToolWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-stale-history-\(UUID())")
        let board = NSPasteboard(name: .init("DeskCapture-stale-history-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let source = WorkflowCorpus.texture(width: 80, height: 60, seed: 42)
        let started = expectation(description: "history read running off main")
        let proceed = DispatchSemaphore(value: 0)
        defer { proceed.signal() }
        let store = CaptureStore(directory: directory)
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false, historyImageReader: { _ in
            XCTAssertFalse(Thread.isMainThread); started.fulfill()
            guard proceed.wait(timeout: .now() + 3) == .success else { throw CaptureError.message("Owned history fixture timed out") }
            return source
        })
        let record = try await store.addAsync(source, mode: .region)
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        app.transform(record)
        await fulfillment(of: [started], timeout: 2)
        _ = try await store.removeBatch([record.id])
        proceed.signal()
        await app.waitForPendingHistoryImage()
        let created = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }
        defer { created.forEach { $0.close() } }
        XCTAssertTrue(created.isEmpty, "A deleted history record must not open a late editor")
    }

    func testCancelledQueuedEncoderDoesNotStartItsOperation() async throws {
        let started = expectation(description: "first native operation started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await ClipboardImageEncoding.run {
                started.fulfill()
                guard release.wait(timeout: .now() + 3) == .success else { throw CaptureError.message("Owned encoding fixture timed out") }
                return .init(png: Data(), tiff: nil)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let queued = Task {
            try await ClipboardImageEncoding.run {
                XCTFail("Cancelled queued encoder must not touch its input")
                return .init(png: Data(), tiff: nil)
            }
        }
        await Task.yield()
        queued.cancel(); release.signal()
        _ = try await first.value
        do { _ = try await queued.value; XCTFail("Cancelled queued encoding was delivered") }
        catch is CancellationError { }
    }

    func testParentCancellationReachesRunningImageEncoder() async throws {
        let started = expectation(description: "encoding started off main")
        let stopped = expectation(description: "encoding observed cancellation")
        let task = Task {
            try await ClipboardImageEncoding.run {
                defer { stopped.fulfill() }
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.001)
                }
                XCTFail("Encoder did not receive parent cancellation")
                return ClipboardImageEncoding.Payload(png: Data(), tiff: nil)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled result must not reach delivery") }
        catch is CancellationError { }
        await fulfillment(of: [stopped], timeout: 2)
    }

    @MainActor
    func testConsecutiveCopiesDeliverOnlyLatestImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-delivery-test-\(UUID())")
        let board = NSPasteboard(name: .init("DeskCapture-latest-copy-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let app = AppCoordinator(store: CaptureStore(directory: directory), imagePasteboard: board, registerHotKeys: false)
        var deliveries = 0
        app.onImageCopyCompleted = { deliveries += 1 }
        app.copy(WorkflowCorpus.texture(width: 120, height: 80, seed: 42))
        app.copy(WorkflowCorpus.texture(width: 48, height: 32, seed: 73))
        await app.waitForPendingImageCopy()
        let data = try XCTUnwrap(board.data(forType: .png))
        let decoder = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
        XCTAssertEqual(image.width, 48); XCTAssertEqual(image.height, 32)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testNamedPasteboardDeliveryAndLaterWriterProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-delivery-test-\(UUID())")
        let board = NSPasteboard(name: NSPasteboard.Name("DeskCapture-delivery-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let app = AppCoordinator(store: CaptureStore(directory: directory), imagePasteboard: board, registerHotKeys: false)
        let source = WorkflowCorpus.texture(width: 120, height: 80, seed: 42)
        var delivered = 0
        app.onImageCopyCompleted = { delivered += 1 }
        app.copy(source)
        await app.waitForPendingImageCopy()
        let data = try XCTUnwrap(board.data(forType: .png))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 80)
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(app.store.records.isEmpty)
        app.copy(source)
        board.clearContents(); board.setString("later copy", forType: .string)
        await app.waitForPendingImageCopy()
        XCTAssertEqual(board.string(forType: .string), "later copy")
        XCTAssertNil(board.data(forType: .png))
        XCTAssertEqual(delivered, 1, "Late encoder must not report delivery or overwrite newer content")
    }
}
