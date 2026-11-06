import XCTest
import AppKit
import AVFoundation
import SwiftUI
@testable import DeskCapture

final class EditorMinimumLayoutTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-owned-layout-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message("Owned layout encoder stalled") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 170, CVPixelBufferGetDataSize(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 3)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600)); input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
    @MainActor private func snapshot(_ window: NSWindow, named name: String, temporary root: URL) async throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let destination = ProcessInfo.processInfo.environment["DESKCAPTURE_LAYOUT_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) } ?? root
        let output = destination.appendingPathComponent(name + ".png")
        try await Task.detached {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try CaptureImageExport.png(image, to: output)
        }.value
        XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
    }
    @MainActor private func descendant<T: NSView>(_ view: NSView, type: T.Type) -> T? {
        if let match = view as? T { return match }
        return view.subviews.compactMap { descendant($0, type: type) }.first
    }
    @MainActor func testVideoProductionEntryRendersBothAppearancesAtMinimumContentSize() async throws {
        _ = NSApplication.shared
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("owned-minimum.mp4"); try await movie(source)
        let board = NSPasteboard(name: .init("DeskCapture-layout-\(UUID())")); defer { board.releaseGlobally() }
        let app = AppCoordinator(store: CaptureStore(directory: root.appendingPathComponent("history")), imagePasteboard: board, registerHotKeys: false)
        app.showVideo(source, imported: true)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == L10n.text("视频编辑 — \(source.lastPathComponent)") })
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(NSSize(width: 780, height: 540))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.bounds.width, 780, accuracy: 1); XCTAssertEqual(content.bounds.height, 540, accuracy: 1)
        let split = try XCTUnwrap(descendant(content, type: NSSplitView.self))
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[0].bounds.width, 369)
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].bounds.width, 319)
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await snapshot(window, named: "video-minimum-\(label)", temporary: root)
        }
        withExtendedLifetime(app) {}
    }
    @MainActor func testImageProductionEntryRendersBothAppearancesAtMinimumFrame() async throws {
        _ = NSApplication.shared
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard(name: .init("DeskCapture-layout-image-\(UUID())")); defer { board.releaseGlobally() }
        let store = CaptureStore(directory: root.appendingPathComponent("history"))
        let record = try store.add(WorkflowCorpus.texture(width: 800, height: 600, seed: 42), mode: .region)
        let app = AppCoordinator(store: store, imagePasteboard: board, registerHotKeys: false)
        let initial = Set(NSApp.windows.map(\.windowNumber))
        app.openEditor(record)
        var opened: NSWindow?
        for _ in 0..<100 where opened == nil {
            opened = NSApp.windows.first { !initial.contains($0.windowNumber) && $0.title == "\(record.title) — DeskCapture" }
            if opened == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let window = try XCTUnwrap(opened); defer { window.close() }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 760, height: 540)), display: false)
        XCTAssertEqual(window.frame.width, 760, accuracy: 1); XCTAssertEqual(window.frame.height, 540, accuracy: 1)
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await snapshot(window, named: "image-minimum-\(label)", temporary: root)
        }
        withExtendedLifetime(app) {}
    }
}
