import XCTest
import AVFoundation
@testable import DeskCapture

final class FragmentedWriterTests: XCTestCase {
    private func sample(_ time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, []); memset(CVPixelBufferGetBaseAddress(buffer), 180, CVPixelBufferGetDataSize(buffer)); CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    func testRealEncoderWritesReadableFragmentBeforeNormalFinish() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-fragment-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("segment.mov")
        let writer = try FragmentedScreenWriter(url: file, width: 64, height: 48, fps: 30, systemAudio: false, microphone: false, failure: { _ in })
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            for index in 0..<150 {
                try Task.checkCancellation()
                await writer.submitDiagnosticVideo(try sample(start + CMTime(value: Int64(index), timescale: 30)))
                try await Task.sleep(for: .milliseconds(10))
            }
            // Copy the on-disk prefix while the original writer is still open.
            // This checks fragment readability, not OS kill/power-loss durability.
            let prefix = folder.appendingPathComponent("interrupted-prefix.mov")
            try FileManager.default.copyItem(at: file, to: prefix)
            let asset = AVURLAsset(url: prefix), duration = try await asset.load(.duration).seconds
            XCTAssertGreaterThan(duration, 0.5)
            let generator = AVAssetImageGenerator(asset: asset)
            let image = try await generator.image(at: CMTime(seconds: min(0.3, duration / 2), preferredTimescale: 600))
            XCTAssertEqual(image.image.width, 64)
            let finished = try await writer.finish(at: start + CMTime(seconds: 5, preferredTimescale: 600))
            XCTAssertGreaterThan(finished.videoFrames, 30)
            XCTAssertEqual(finished.sourceVideoFrames, finished.videoFrames - finished.heldVideoFrames + finished.droppedVideo)
            XCTAssertEqual(finished.duration, 5, accuracy: 0.04)
            let finalDuration = try await AVURLAsset(url: file).load(.duration).seconds
            XCTAssertEqual(finalDuration, 5, accuracy: 0.1)
        } catch {
            _ = try? await writer.finish(at: start + CMTime(seconds: 5, preferredTimescale: 600)); throw error
        }
    }
    func testCaptureCountersAccumulateAcrossPauseSegments() {
        var stats = RecordingCaptureStatistics()
        stats.append(.init(duration: 2, videoFrames: 50, droppedVideo: 3, droppedAudio: 1, sourceVideoFrames: 51, heldVideoFrames: 2))
        stats.append(.init(duration: 1, videoFrames: 30, droppedVideo: 0, droppedAudio: 2, sourceVideoFrames: 29, heldVideoFrames: 1))
        XCTAssertEqual(stats.segments, 2); XCTAssertEqual(stats.sourceVideoFrames, 80)
        XCTAssertEqual(stats.writtenVideoFrames, 80); XCTAssertEqual(stats.heldVideoFrames, 3)
        XCTAssertEqual(stats.droppedVideo, 3); XCTAssertEqual(stats.droppedAudio, 3)
    }
}
