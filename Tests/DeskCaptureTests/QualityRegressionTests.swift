import XCTest
import AppKit
import AVFoundation
@testable import DeskCapture

final class QualityRegressionTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-quality-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return try XCTUnwrap(context.makeImage())
    }
    @MainActor
    func testCancellationReturnsPromptlyAndStopsCaptureWork() async throws {
        var stopped = false
        let task = Task {
            try await captureWithTimeout(10) { () async throws -> Int in
                defer { stopped = true }
                try await Task.sleep(for: .seconds(10)); return 1
            }
        }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation must fail") } catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(10)); XCTAssertTrue(stopped)
    }
    @MainActor
    func testTimeoutCancelsOperationAndLateCompletionCannotResumeTwice() async throws {
        var stopped = false
        do {
            let _: Int = try await captureWithTimeout(0.01) {
                defer { stopped = true }
                try await Task.sleep(for: .seconds(5)); return 1
            }
            XCTFail("Must time out")
        } catch { XCTAssertEqual(error.localizedDescription, L10n.text("屏幕捕获没有及时响应。请确认系统权限授予的是当前 DeskCapture，并重启 App 后重试。")) }
        try await Task.sleep(for: .milliseconds(10)); XCTAssertTrue(stopped)
        let value = try await captureWithTimeout { 2 }; XCTAssertEqual(value, 2)
    }
    @MainActor
    func testAsyncHistorySnapshotsEditorBeforeEncodingAndPersistsProject() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory), document = AnnotationDocument(image: try image())
        document.add(document.makeMark(tool: .rectangle, points: [.zero, CGPoint(x: 0.5, y: 0.5)]))
        let record = try await store.addAsync(try XCTUnwrap(document.render()), mode: .region, document: document, backingScale: 2)
        let restored = CaptureStore(directory: directory)
        XCTAssertEqual(restored.records.count, 1); XCTAssertEqual(restored.records[0].id, record.id)
        XCTAssertEqual(restored.records[0].backingScale, 2)
        XCTAssertEqual(try XCTUnwrap(restored.document(for: record)).marks.count, 1)
        XCTAssertEqual(try CaptureImageRead.load(restored.url(for: record)).width, 64)
    }
    @MainActor
    func testAsyncHistoryFailedIndexCommitCleansFilesAndKeepsRecords() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("history.json"), withIntermediateDirectories: true)
        do { _ = try await store.addAsync(try image(), mode: .region); XCTFail("Index commit should fail") } catch {}
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), [".history.lock", "history.json"])
    }
    func testTransformExtremeDimensionsAndGapFailWithoutIntegerOverflow() throws {
        let image = try image()
        XCTAssertThrowsError(try CaptureImageTransform.render(image, width: Int.max, height: Int.max))
        XCTAssertThrowsError(try CaptureImageTransform.combine([image, image], horizontal: true, gap: Int.max))
        XCTAssertThrowsError(try CaptureImageTransform.combine([image, image], horizontal: false, gap: -1))
        XCTAssertEqual(ImageTransformView.linkedHeight(width: Int.max, ratio: 0.01), 0)
        XCTAssertEqual(ImageTransformView.linkedHeight(width: 100, ratio: .leastNonzeroMagnitude), 0)
        XCTAssertEqual(ImageTransformView.linkedHeight(width: 100, ratio: 2), 50)
    }
    func testCorruptProjectRejectsInvalidMarkBeforeRendering() throws {
        let document = AnnotationDocument(image: try image())
        document.add(document.makeMark(tool: .text, points: [.zero], text: "test"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: document.projectData()) as? [String: Any])
        var marks = try XCTUnwrap(json["marks"] as? [[String: Any]])
        marks[0]["fontSize"] = -1; json["marks"] = marks
        XCTAssertThrowsError(try AnnotationDocument(projectData: JSONSerialization.data(withJSONObject: json)))
    }
    @MainActor
    func testTutorialExportDoesNotBlockMainActorAndPDFHasAllPages() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        try CaptureImageExport.png(try image(), to: directory.appendingPathComponent("step.png"))
        let steps = (0..<40).map { TutorialStep(title: "步骤 \($0)", detail: "验证导出", file: "step.png", clickX: 0.5, clickY: 0.5) }
        let folder = directory.appendingPathComponent("session"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("step.png"), to: folder.appendingPathComponent("step.png"))
        try JSONEncoder().encode(steps).write(to: folder.appendingPathComponent("steps.json"))
        let recorder = TutorialRecorder(root: directory)
        var heartbeat = 0
        let beat = Task { while !Task.isCancelled { heartbeat += 1; try? await Task.sleep(for: .milliseconds(1)) } }
        defer { beat.cancel() }
        let output = directory.appendingPathComponent("tutorial.pdf")
        try await recorder.export(output)
        XCTAssertGreaterThan(heartbeat, 1)
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL)); XCTAssertEqual(pdf.numberOfPages, 40)
        let html = directory.appendingPathComponent("tutorial.html"); try await recorder.export(html)
        XCTAssertEqual(try String(contentsOf: html, encoding: .utf8).components(separatedBy: "<section>").count - 1, 40)
    }
    func testMissingTutorialImagePreservesExistingPDFAndRemovesStage() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("keep.pdf"), sentinel = Data("existing".utf8)
        try sentinel.write(to: output)
        let steps = [TutorialStep(title: "Missing", file: "missing.png", clickX: 0, clickY: 0)]
        XCTAssertThrowsError(try TutorialRecorder.exportSnapshot(steps, directory: directory, to: output))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.pdf"])
    }

    func testTrimmingRotatedMovieWithShortAudioPreservesOrientationAndTracks() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let videoURL = directory.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)); if writer.status == .failed { throw writer.error! } }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 128, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600)); input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let audioURL = directory.appendingPathComponent("short.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8820)); buffer.frameLength = 8820
            for index in 0..<8820 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05) * 0.1) }
            try file.write(from: buffer)
        }
        let videoAsset = AVURLAsset(url: videoURL), audioAsset = AVURLAsset(url: audioURL)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let sourceVideos = try await videoAsset.loadTracks(withMediaType: .video)
        let sourceVideo = try XCTUnwrap(sourceVideos.first)
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        let audio = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let sourceAudios = try await audioAsset.loadTracks(withMediaType: .audio)
        let sourceAudio = try XCTUnwrap(sourceAudios.first)
        try audio.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.2, preferredTimescale: 600)), of: sourceAudio, at: CMTime(seconds: 0.6, preferredTimescale: 600))
        let mux = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let source = directory.appendingPathComponent("source.mov")
        try await VideoExport.export(mux, to: source, as: .mov)
        let output = directory.appendingPathComponent("trim.mp4")
        try await VideoTrimmer.export(source, to: output, start: 0.25, end: 1.25)
        let result = AVURLAsset(url: output), duration = try await result.load(.duration).seconds
        let tracks = try await result.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first), size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        XCTAssertEqual(display.width, 48, accuracy: 1); XCTAssertEqual(display.height, 64, accuracy: 1)
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        let audioTracks = try await result.loadTracks(withMediaType: .audio); XCTAssertEqual(audioTracks.count, 1)
        _ = try await AVAssetImageGenerator(asset: result).image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    func testHistoryDeleteFailedIndexCommitRestoresImageAndEditableProject() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory), document = AnnotationDocument(image: try image())
        document.add(document.makeMark(tool: .rectangle, points: [.zero, CGPoint(x: 0.5, y: 0.5)]))
        let record = try store.add(try image(), mode: .region, document: document)
        let index = directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.delete(record))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: record).path))
        XCTAssertEqual(try XCTUnwrap(store.document(for: record)).marks.count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".delete-history-") })
    }
    func testCancelledPDFExportPreservesExistingDestinationAndCleansStage() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("keep.pdf"), sentinel = Data("existing content".utf8), image = try image()
        try sentinel.write(to: output)
        let exporting = Task.detached { while !Task.isCancelled { await Task.yield() }; try CaptureImageExport.pdf(image, to: output) }
        exporting.cancel()
        do { try await exporting.value; XCTFail("Export should cancel") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.pdf"])
    }

    @MainActor
    func testDiagnosticRecorderPreferencesNeverModifyStandardSettings() throws {
        let suite = "DeskCapture-isolated-recorder-\(UUID())", key = "recordFPS"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let previous = AppPreferences.standard.object(forKey: key) as? Int
        preferences.set(30, forKey: key)
        let recorder = ScreenRecorder(preferences: preferences)
        XCTAssertEqual(recorder.fps, 30, "The normal recording target is 30fps")
        recorder.fps = 60
        XCTAssertEqual(ScreenRecorder(preferences: preferences).fps, 60, "Keep an existing explicit setting")
        XCTAssertEqual(preferences.integer(forKey: key), 60)
        XCTAssertEqual(AppPreferences.standard.object(forKey: key) as? Int, previous)
    }

    @MainActor
    func testBackgroundFormattingCannotReplaceNewerText() async throws {
        let source = "[" + Array(repeating: "\"DeskCapture\"", count: 10_000).joined(separator: ",") + "]"
        let editor = ClipboardEditor(text: source, name: "large.json", report: { _ in })
        defer { editor.window.close() }
        editor.formatText(); XCTAssertTrue(editor.isFormatting)
        let latest = "{\"changed\":true}"
        editor.textView.string = latest
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        for _ in 0..<100 where editor.isFormatting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.isFormatting)
        XCTAssertEqual(editor.textView.string, latest)
    }
    func testDeepXMLIsRejectedBeforeQuadraticIndentationAllocation() {
        let source = String(repeating: "<item>", count: 150) + "x" + String(repeating: "</item>", count: 150)
        XCTAssertThrowsError(try XMLTextFormatter.format(source))
    }

    @MainActor
    func testIdleTutorialStopCannotOverwriteNewerSavedSteps() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let session = directory.appendingPathComponent("session"); try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appendingPathComponent("steps.json")
        let original = [TutorialStep(title: "old", file: "step.png", clickX: 0, clickY: 0)]
        try JSONEncoder().encode(original).write(to: file)
        let recorder = TutorialRecorder(root: directory)
        XCTAssertEqual(recorder.steps.first?.title, "old")
        let newer = [TutorialStep(title: "newer saved version", file: "step.png", clickX: 0, clickY: 0)]
        let data = try JSONEncoder().encode(newer); try data.write(to: file)
        recorder.stop(notify: false)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    @MainActor
    func testConcurrentHistoryEncodingKeepsNewestCaptureFirst() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 3840, height: 2160, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let large = try XCTUnwrap(context.makeImage()), small = try image(), store = CaptureStore(directory: directory)
        let first = Task { try await store.addAsync(large, mode: .region) }
        try await Task.sleep(for: .milliseconds(1))
        let second = Task { try await store.addAsync(small, mode: .region) }
        let old = try await first.value, new = try await second.value
        XCTAssertLessThan(old.createdAt, new.createdAt)
        XCTAssertEqual(store.records.map(\.id), [new.id, old.id])
        XCTAssertEqual(CaptureStore(directory: directory).records.map(\.id), [new.id, old.id])
    }
}
