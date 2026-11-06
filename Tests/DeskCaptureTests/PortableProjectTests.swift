import XCTest
import AppKit
import AVFoundation
import PDFKit
@testable import DeskCapture

final class PortableProjectTests: XCTestCase {
    private func root() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-project-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); return folder
    }
    private func png(_ file: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        try CaptureImageExport.png(try XCTUnwrap(context.makeImage()), to: file)
    }
    private func movie(_ output: URL) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard writer.status != .failed, ProcessInfo.processInfo.systemUptime < deadline else { throw writer.error ?? CaptureError.message("Fixture stalled") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixel: CVPixelBuffer?; XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 180, CVPixelBufferGetDataSize(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 0.4, preferredTimescale: 600)); input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
    func testVideoRelocationReopensDependenciesAndCanRenderAgain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals"); try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        let video = originals.appendingPathComponent("capture.mp4"); try await movie(video)
        let original = try Data(contentsOf: video)
        let raw = originals.appendingPathComponent("raw.mp4"); try original.write(to: raw)
        try original.write(to: RecordingCamera.url(for: video))
        try JSONEncoder().encode(RecordingInteractions(smoothCursor: true, events: [], recordedFPS: 30)).write(to: RecordingInteractions.url(for: raw))
        var metadata = RecordingInteractions(smoothCursor: false, events: [], recordedFPS: 30); metadata.editableCursorSource = "raw.mp4"
        try JSONEncoder().encode(metadata).write(to: RecordingInteractions.url(for: video))
        let music = originals.appendingPathComponent("music.wav"), format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: music, settings: format.settings), buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)); buffer.frameLength = 24000
            for i in 0..<24000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.02) }; try file.write(from: buffer)
        }
        var effects = RecordingEffectsOptions(); effects.camera.enabled = false; effects.smartZoom = false; effects.background = false; effects.edit = .init(musicPath: music.path, musicName: "music")
        let rows = [CaptionSegment(start: 0.12, end: 0.24, text: "可校对字幕")]
        let snapshot = RecordingEditSnapshot(captions: rows, studio: .init(effects: effects, trimStart: 0.1, trimEnd: 0.3)), expected = try RecordingEditStore.fingerprint(video)
        let package = root.appendingPathComponent("original.deskvideo")
        try await Task.detached { try PortableProject.exportVideo(video, snapshot: snapshot, expected: expected, to: package) }.value
        XCTAssertEqual(try Data(contentsOf: video), original)
        let moved = root.appendingPathComponent("moved.deskvideo"); try FileManager.default.moveItem(at: package, to: moved)
        try FileManager.default.removeItem(at: originals) // Only this test's own fixtures.
        let restored = try await PortableProject.restore(moved, in: root.appendingPathComponent("managed")), entry = try XCTUnwrap(restored.video)
        XCTAssertEqual(try Data(contentsOf: entry), original)
        var project = try XCTUnwrap(RecordingEditStore.load(entry))
        XCTAssertEqual(project.studio.trimStart, 0.1); XCTAssertEqual(project.studio.trimEnd, 0.3)
        let relocatedMusic = try XCTUnwrap(project.studio.effects?.edit?.musicPath)
        XCTAssertTrue(relocatedMusic.hasPrefix(restored.directory.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: relocatedMusic))
        _ = try EditableCursorSource.resolve(entry, metadata: RecordingInteractions.load(entry))
        project.captions[0].text = "继续校对"; _ = try RecordingEditStore.save(project, for: entry, expected: RecordingEditStore.fingerprint(entry))
        XCTAssertEqual(VideoTranscript.load(entry)[0].text, "继续校对")
        var options = try XCTUnwrap(project.studio.effects); options.captions = project.captions
        let result = root.appendingPathComponent("rendered.mp4"); try await RecordingEffectsExporter.export(entry, to: result, options: options, start: 0.1, end: 0.3)
        let resultAsset = AVURLAsset(url: result), duration = try await resultAsset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0.15); XCTAssertLessThan(duration, 0.3)
        let audioTracks = try await resultAsset.loadTracks(withMediaType: .audio); XCTAssertFalse(audioTracks.isEmpty)
    }
    func testMergedTutorialRetainsAllImagesLongNotesAndPortableEditing() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try png(source.appendingPathComponent("a.png")); try png(source.appendingPathComponent("b.png"))
        let first = TutorialStep(title: "first", detail: String(repeating: "long note line\n", count: 300) + "END-SENTINEL-42", file: "a.png", clickX: 0.5, clickY: 0.5, timestamp: 10, windowKey: "test-window")
        let second = TutorialStep(title: "second", detail: "second notes", file: "b.png", clickX: 0.51, clickY: 0.5, timestamp: 10.8, windowKey: "test-window")
        XCTAssertEqual(try TutorialEditing.firstNearby([first, second], directory: source), 0)
        let merged = try TutorialEditing.merge([first, second], at: 0)
        XCTAssertEqual(merged.count, 1); XCTAssertEqual(TutorialEditing.frames(merged[0]).count, 2)
        let split = try TutorialEditing.split(merged, id: merged[0].id)
        XCTAssertEqual(split.map(\.file), ["a.png", "b.png"]); XCTAssertEqual(split.map(\.detail), [first.detail, second.detail])
        let pdf = root.appendingPathComponent("tutorial.pdf"), html = root.appendingPathComponent("tutorial.html"), package = root.appendingPathComponent("tutorial.desktutorial")
        try await Task.detached {
            try TutorialExporter.export(merged, directory: source, to: pdf)
            try TutorialExporter.export(merged, directory: source, to: html)
            try PortableProject.exportTutorial(merged, directory: source, to: package)
        }.value
        let document = try XCTUnwrap(PDFDocument(url: pdf)); XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        XCTAssertTrue(document.string?.contains("END-SENTINEL-42") == true); XCTAssertTrue(document.string?.contains("second notes") == true)
        XCTAssertEqual(try String(contentsOf: html, encoding: .utf8).components(separatedBy: "<figure>").count - 1, 2)
        try FileManager.default.removeItem(at: source)
        let restored = try await PortableProject.restore(package, in: root.appendingPathComponent("managed")), steps = try XCTUnwrap(restored.steps)
        XCTAssertEqual(steps, merged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.directory.appendingPathComponent("b.png").path))
        let saved = try TutorialPersistence.data(restored.directory)
        _ = try TutorialPersistence.save([first, second], directory: restored.directory, expected: saved)
        XCTAssertEqual(try JSONDecoder().decode([TutorialStep].self, from: XCTUnwrap(TutorialPersistence.data(restored.directory))), [first, second])
    }
    func testFailedCancelledAndCorruptPackagesPreserveDestinationAndCleanStage() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try png(root.appendingPathComponent("step.png"))
        let steps = [TutorialStep(title: "one", file: "step.png", clickX: 0.5, clickY: 0.5)], destination = root.appendingPathComponent("existing.desktutorial")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("sentinel"), bytes = Data("preserve".utf8); try bytes.write(to: sentinel)
        XCTAssertThrowsError(try PortableProject.exportTutorial(steps, directory: root, to: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        let cancelled = root.appendingPathComponent("cancelled.desktutorial")
        do {
            try await Task.detached { try PortableProject.exportTutorial(steps, directory: root, to: cancelled, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } }) }.value
            XCTFail("Must cancel before commit")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        let corrupt = root.appendingPathComponent("corrupt.desktutorial"); try PortableProject.exportTutorial(steps, directory: root, to: corrupt)
        try Data("tampered".utf8).write(to: corrupt.appendingPathComponent("step.png"))
        let managed = root.appendingPathComponent("managed")
        do { _ = try await PortableProject.restore(corrupt, in: managed); XCTFail("Must reject checksum/size mismatch") } catch {}
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: managed.path).isEmpty) == true)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".DeskCapture-project-") })
        XCTAssertFalse(PortableProject.safe("../outside.png")); XCTAssertFalse(PortableProject.safe("sub/file.png"))
    }
}
