import XCTest
import AVFoundation
import AppKit
@testable import DeskCapture

final class CameraSegmentGapTests: XCTestCase {
    func testAllCompositionEntrypointsShareCameraAvailabilityPolicy() {
        for state in [RecordingCameraMaterial.checking, .missing, .ready, .unreadable] {
            XCTAssertFalse(state.blocksComposition(enabled: false, requested: true))
        }
        XCTAssertTrue(RecordingCameraMaterial.checking.blocksComposition(enabled: true, requested: false))
        XCTAssertTrue(RecordingCameraMaterial.unreadable.blocksComposition(enabled: true, requested: false))
        XCTAssertTrue(RecordingCameraMaterial.missing.blocksComposition(enabled: true, requested: true))
        XCTAssertFalse(RecordingCameraMaterial.missing.blocksComposition(enabled: true, requested: false))
        XCTAssertFalse(RecordingCameraMaterial.ready.blocksComposition(enabled: true, requested: true))
    }
    private func movie(_ url: URL, duration: Double = 1) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(duration * 10) {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard writer.status != .failed, ProcessInfo.processInfo.systemUptime < deadline else { throw writer.error ?? CaptureError.message("Fixture encoder stalled") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 160, CVPixelBufferGetDataSize(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600)); input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
    func testCameraDecoderCrosses15SecondsAndCanSeekBackWithoutLosingFrames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("camera.mov")
        try await movie(source, duration: 18)
        let cache = CameraFrameCache(url: source, removeBackground: false)
        for time in [0.0, 0.2, 14.9, 15, 15.1, 16.4, 17.8, 2, 15.2] {
            let sample = try await cache.sample(at: time)
            XCTAssertNotNil(sample, "Camera sample absent at \(time)")
            if let sample { XCTAssertLessThanOrEqual(abs(sample.time - time), 0.16) }
        }
        let count = try await withThrowingTaskGroup(of: Bool.self) { group in
            for time in [14.8, 15.0, 15.3, 3.0] { group.addTask { try await cache.sample(at: time) != nil } }
            var found = 0
            for try await present in group { if present { found += 1 } }
            return found
        }
        XCTAssertEqual(count, 4)
        await cache.cancel()
    }
    @MainActor
    func testPlayingSeekContinuesButPauseDuringSeekWins() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-transport-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await movie(source, duration: 3)
        let playback = VideoEditorPlaybackController()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 240)); surface.wantsLayer = true
        playback.presentationLayer.frame = surface.bounds; surface.layer?.addSublayer(playback.presentationLayer)
        window.contentView = surface; window.orderFront(nil)
        defer { playback.stop(); window.close() }
        try await playback.present(AVPlayerItem(url: source), at: { 0 })
        playback.toggle(); XCTAssertTrue(playback.isPlaying)
        playback.seek(1.2); XCTAssertTrue(playback.isPlaying)
        var deadline = ProcessInfo.processInfo.systemUptime + 5
        while playback.isSeeking, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(playback.isSeeking); XCTAssertTrue(playback.isPlaying)
        playback.seek(0.7); playback.seek(1.5); playback.seek(0.4); playback.pause()
        deadline = ProcessInfo.processInfo.systemUptime + 5
        while playback.isSeeking, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(playback.isSeeking); XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.player.currentTime().seconds, 0.4, accuracy: 0.06)
    }
    func testCameraMaterialDistinguishesMissingUnreadableAndUsableWithoutChangingFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-material-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = folder.appendingPathComponent("screen.mp4"), camera = RecordingCamera.url(for: screen)
        let missing = try await RecordingCameraMaterial.inspect(for: screen)
        XCTAssertEqual(missing, .missing)
        let sentinel = Data("not a camera movie".utf8)
        try sentinel.write(to: camera)
        let unreadable = try await RecordingCameraMaterial.inspect(for: screen)
        XCTAssertEqual(unreadable, .unreadable)
        XCTAssertEqual(try Data(contentsOf: camera), sentinel)
        try FileManager.default.removeItem(at: camera)
        try await movie(camera)
        let original = try Data(contentsOf: camera)
        let ready = try await RecordingCameraMaterial.inspect(for: screen)
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(try Data(contentsOf: camera), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: screen.path))
    }

    @MainActor
    func testScreenOriginalIsNotAutoCopiedWhenCameraMaterialExists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let board = NSPasteboard(name: .init("DeskCapture-QA-camera-delivery-\(UUID())"))
        let initialWindows = Set(NSApp.windows.map(\.windowNumber))
        defer {
            for window in NSApp.windows where window is VideoResultPanel && !initialWindows.contains(window.windowNumber) { window.close() }
            board.releaseGlobally(); try? FileManager.default.removeItem(at: folder)
        }
        let source = folder.appendingPathComponent("screen.mov")
        try await movie(source)
        try FileManager.default.copyItem(at: source, to: RecordingCamera.url(for: source))
        board.setString("external clipboard stays", forType: .string)
        let app = AppCoordinator(store: CaptureStore(directory: folder.appendingPathComponent("history")), imagePasteboard: board, registerHotKeys: false)
        app.showVideo(source)
        XCTAssertEqual(board.string(forType: .string), "external clipboard stays")
        try FileManager.default.removeItem(at: RecordingCamera.url(for: source))
        app.showVideo(source, imported: true)
        XCTAssertEqual(board.string(forType: .string), "external clipboard stays")
        app.showVideo(source)
        let copied = try XCTUnwrap(board.string(forType: .fileURL))
        XCTAssertEqual(URL(string: copied), source)
        board.clearContents(); board.setString("expected camera is missing", forType: .string)
        app.showVideo(source, cameraWasRequested: true)
        XCTAssertEqual(board.string(forType: .string), "expected camera is missing")
    }

    func testCancelledCameraMaterialCheckDoesNotReturnMissingOrSuccess() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-cancelled-camera-\(UUID()).mp4")
        let task = Task { () throws -> RecordingCameraMaterial in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RecordingCameraMaterial.inspect(for: source)
        }
        do { _ = try await task.value; XCTFail("Cancelled material check returned a result") }
        catch is CancellationError { }
    }

    func testPartialCameraDoesNotInventFrozenSamplesAcrossMissingInterval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-gap-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("partial.mov"), output = folder.appendingPathComponent("joined.mp4")
        try await movie(source)
        try await CameraRecordingSegment.join([.init(url: source, offset: 0, duration: 2), .init(url: nil, offset: 0, duration: 1), .init(url: source, offset: 0.5, duration: 1)], to: output)
        let asset = AVURLAsset(url: output), duration = try await asset.load(.duration).seconds
        // Passthrough MP4 may trim a final empty edit. No fabricated image is
        // required in that tail; the renderer must return nil there.
        XCTAssertGreaterThanOrEqual(duration, 3.45); XCTAssertLessThanOrEqual(duration, 4.1)
        let tracks = try await asset.loadTracks(withMediaType: .video), track = try XCTUnwrap(tracks.first)
        let edits = try await track.load(.segments)
        print("CAMERA_EDIT_MAP", edits.map { ["empty": $0.isEmpty ? 1.0 : 0.0, "sourceStart": $0.timeMapping.source.start.seconds, "sourceDuration": $0.timeMapping.source.duration.seconds, "targetStart": $0.timeMapping.target.start.seconds, "targetDuration": $0.timeMapping.target.duration.seconds] })
        let samples = try await Task.detached { () throws -> [Double] in
            let reader = try AVAssetReader(asset: asset), stream = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(stream); guard reader.startReading() else { throw reader.error ?? CaptureError.message("Fixture reader failed") }
            var times: [Double] = [], diagnostics: [[String: Double]] = []
            while let buffer = stream.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                diagnostics.append(["pts": pts, "samples": Double(CMSampleBufferGetNumSamples(buffer)), "bytes": Double(CMSampleBufferGetTotalSampleSize(buffer))])
                if CMSampleBufferGetImageBuffer(buffer) != nil { times.append(pts) }
            }
            print("CAMERA_GAP_SAMPLES", diagnostics)
            guard reader.status == .completed else { throw reader.error ?? CaptureError.message("Fixture read unfinished") }
            return times
        }.value
        XCTAssertTrue(samples.contains { $0 < 0.9 }); XCTAssertTrue(samples.contains { $0 >= 3 && $0 < 3.6 })
        XCTAssertFalse(samples.contains { $0 > 1.05 && $0 < 2.95 })
        let frameIndex = try await VideoSourceFrameIndex.build(asset: asset, track: track, duration: duration)
        XCTAssertTrue(frameIndex.times.contains { $0 >= 3 && $0 < 3.5 })
        XCTAssertFalse(frameIndex.times.contains { $0 > 1.01 && $0 < 2.99 }, "Compressed media PTS must be mapped through the actual edit list")
        let cache = CameraFrameCache(url: output, removeBackground: false)
        let gap = try await cache.sample(at: 2)
        XCTAssertNil(gap, "A camera gap must not silently display an earlier face frame")
        let missingTail = try await cache.sample(at: 3.8)
        XCTAssertNil(missingTail, "A trimmed empty tail must remain absent")
        await cache.cancel()
    }
    func testInvalidOrEmptyCameraExportPreservesDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-error-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("existing.mp4"), sentinel = Data("keep original destination".utf8)
        try sentinel.write(to: output)
        do { try await CameraRecordingSegment.join([.init(url: nil, offset: 0, duration: 2)], to: output); XCTFail("No camera samples accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        do { try await CameraRecordingSegment.join([.init(url: nil, offset: -1, duration: 2)], to: output); XCTFail("Invalid offset accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }
}
