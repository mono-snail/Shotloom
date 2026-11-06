import XCTest
import CoreImage
import AVFoundation
@testable import DeskCapture

final class VideoPrivacyTests: XCTestCase {
    private func pixels(_ image: CIImage, bounds: CGRect) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(image, toBitmap: &bytes, rowBytes: Int(bounds.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: nil)
        return bytes
    }
    func testOpaqueOverwritesAllSecretPixelsBeforeScalingAndPreservesOutside() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        let a = CIImage(color: .red).cropped(to: bounds), b = CIImage(color: .green).cropped(to: bounds)
        let cue = VideoPrivacyCue(start: 1, end: 2, x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        let timeline = try VideoPrivacyTimeline([cue], duration: 3)
        let resultA = timeline.apply(a, target: .screen, window: 1.5...1.5), resultB = timeline.apply(b, target: .screen, window: 1.5...1.5)
        let bytesA = pixels(resultA, bounds: bounds)
        let rect = try XCTUnwrap(timeline.rectangles(target: .screen, window: 1.5...1.5, bounds: bounds).first?.1)
        let cropA = pixels(resultA, bounds: rect), cropB = pixels(resultB, bounds: rect)
        XCTAssertEqual(cropA, cropB)
        for index in stride(from: 0, to: cropA.count, by: 4) { XCTAssertEqual(Array(cropA[index..<index + 4]), [0, 0, 0, 255]) }
        XCTAssertEqual(Array(bytesA.prefix(4)), [255, 0, 0, 255])
        XCTAssertEqual(pixels(a, bounds: bounds).first, 255)
    }
    func testHighlightsNeverOverrideOpaqueOverlapAndTargetsStaySeparate() throws {
        var opaque = VideoPrivacyCue(start: 0, end: 2, x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        var highlight = opaque; highlight.id = UUID(); highlight.kind = .highlight
        opaque.target = .canvas; highlight.target = .canvas
        let timeline = try VideoPrivacyTimeline([opaque, highlight], duration: 3)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100), image = CIImage(color: .white).cropped(to: bounds)
        XCTAssertEqual(pixels(timeline.apply(image, target: .screen, window: 1...1), bounds: bounds), pixels(image, bounds: bounds))
        let bytes = pixels(timeline.apply(image, target: .canvas, window: 1...1), bounds: CGRect(x: 30, y: 30, width: 1, height: 1))
        XCTAssertEqual(bytes, [0, 0, 0, 255])
    }
    func testManualMotionCoversFullFrameSupportAndVFRHold() throws {
        let cue = VideoPrivacyCue(start: 1, end: 2, x: 0.1, y: 0.1, width: 0.2, height: 0.2, endX: 0.6, endY: 0.5)
        let timeline = try VideoPrivacyTimeline([cue], duration: 3)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let covered = try XCTUnwrap(timeline.rectangles(target: .screen, window: 1.25...1.75, bounds: bounds).first?.1)
        for time in stride(from: 1.25, through: 1.75, by: 0.05) {
            let rect = cue.rect(at: time), pixels = CGRect(x: rect.minX * 1000, y: rect.minY * 1000, width: rect.width * 1000, height: rect.height * 1000)
            XCTAssertTrue(covered.contains(pixels))
        }
        let index = VideoSourceFrameIndex(times: [0, 0.04, 1.5, 1.54], duration: 2)
        XCTAssertEqual(index.covering(0.8...0.82), 0.04...1.5)
        XCTAssertFalse(timeline.rectangles(target: .screen, window: index.covering(0.8...0.82), bounds: bounds).isEmpty)
    }
    func testCutRepeatSpeedAndConservativeBoundaryMapping() throws {
        let plan = try VideoEditPlan(duration: 5, start: 0, end: 5, captions: [], sections: [VideoSection(start: 3, end: 5, speed: 2), VideoSection(start: 0, end: 2), VideoSection(start: 3, end: 5, speed: 0.5)])
        let cue = VideoPrivacyCue(start: 3.2, end: 3.8), timeline = try VideoPrivacyTimeline([cue], duration: 5)
        let mapped = timeline.mapped(to: plan)
        XCTAssertEqual(mapped.count, 2); XCTAssertEqual(mapped[0].start, 0.1, accuracy: 0.0001); XCTAssertEqual(mapped[1].start, 3.4, accuracy: 0.0001)
        for time in plan.mapAll(3.5) { XCTAssertFalse(timeline.rectangles(target: .screen, window: VideoPrivacyTimeline.sourceWindow(outputTime: time, fps: 30, plan: plan), bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty) }
        let atCut = VideoPrivacyTimeline.sourceWindow(outputTime: 1, fps: 30, plan: plan)
        XCTAssertEqual(atCut.lowerBound, 0, accuracy: 0.0001); XCTAssertLessThan(atCut.upperBound, 0.04)
    }
    func testMediaFrameProjectionHandlesGapsTrimsSpeedAndRepeatedSource() throws {
        func mapping(_ sourceStart: Double, _ sourceLength: Double, _ targetStart: Double, _ targetLength: Double) -> CMTimeMapping {
            CMTimeMapping(source: CMTimeRange(start: CMTime(seconds: sourceStart, preferredTimescale: 600), duration: CMTime(seconds: sourceLength, preferredTimescale: 600)),
                          target: CMTimeRange(start: CMTime(seconds: targetStart, preferredTimescale: 600), duration: CMTime(seconds: targetLength, preferredTimescale: 600)))
        }
        let raw = [0.0, 0.1, 0.5, 0.9, 1, 1.5, 1.9]
        let gap = try VideoSourceFrameIndex.project(raw, mappings: [mapping(0, 1, 0, 1), mapping(1.5, 0.5, 3, 0.5)], duration: 3.5)
        XCTAssertEqual(gap.count, 6)
        for (actual, expected) in zip(gap, [0.0, 0.1, 0.5, 0.9, 3, 3.4]) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
        let repeated = try VideoSourceFrameIndex.project([0, 1, 2, 3], mappings: [mapping(0.5, 1.5, 0, 3), mapping(0.5, 1.5, 3, 0.75)], duration: 3.75)
        for (actual, expected) in zip(repeated, [0.0, 1, 3, 3.25]) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
        XCTAssertEqual(repeated.count, 4)
        XCTAssertThrowsError(try VideoSourceFrameIndex.project(raw, mappings: [mapping(0, 1, 0, 0)], duration: 1))
    }
    func testValidationAndProjectCompatibility() throws {
        XCTAssertThrowsError(try VideoPrivacyTimeline([.init(start: 0, end: 2, x: 0.9, width: 0.3)], duration: 3))
        XCTAssertThrowsError(try VideoPrivacyTimeline([.init(start: 0, end: 2, endX: 0.2)], duration: 3))
        var effects = RecordingEffectsOptions(); effects.privacy = [.init(start: 0, end: 2, target: .camera)]
        XCTAssertEqual(try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects)).privacy, effects.privacy)
        effects.privacy = nil
        XCTAssertNil(try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects)).privacy)
    }
    func testRealVariableFrameHoldExportRedactsSecretOutsideCueClockInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-privacy-vfr-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.mov"), destination = root.appendingPathComponent("output.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for (index, time) in [0.0, 0.04, 1.5, 1.54].enumerated() {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime < deadline, writer.status != .failed else { throw writer.error ?? CaptureError.message("Fixture writer stalled") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(buffer, [])
            let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<48 { for x in 0..<64 { let p = y * stride + x * 4; data[p] = index == 1 ? 0 : 255; data[p + 1] = index == 1 ? 0 : 255; data[p + 2] = 255; data[p + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600)); input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let cadence = try await RecordedFrameCadence.measure(source)
        XCTAssertEqual(cadence.frames, 4)
        XCTAssertEqual(cadence.timestampSpan, 1.54, accuracy: 0.001)
        XCTAssertEqual(cadence.maximumInterval, 1.46, accuracy: 0.001)
        XCTAssertEqual(cadence.p95Interval, 1.46, accuracy: 0.001)
        let original = try Data(contentsOf: source)
        var options = RecordingEffectsOptions(); options.camera.enabled = false; options.background = false; options.smartZoom = false; options.clicks = false; options.shortcuts = false
        options.privacy = [.init(start: 1, end: 1.1, x: 0, y: 0, width: 1, height: 1)]
        let sourceAsset = AVURLAsset(url: source)
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        print("VFR_EDIT_MAP", try await sourceTrack.load(.segments).map { ["sourceStart": $0.timeMapping.source.start.seconds, "sourceDuration": $0.timeMapping.source.duration.seconds, "targetStart": $0.timeMapping.target.start.seconds, "targetDuration": $0.timeMapping.target.duration.seconds] })
        print("VFR_PRIVACY_PHASE source-ready, export-start")
        try await RecordingEffectsExporter.export(source, to: destination, options: options)
        print("VFR_PRIVACY_PHASE export-complete")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        for time in [0.2, 0.8, 1.0, 1.3] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            let center = pixels(CIImage(cgImage: frame), bounds: CGRect(x: 32, y: 24, width: 1, height: 1))
            XCTAssertLessThan(center[0], 16); XCTAssertLessThan(center[1], 16); XCTAssertLessThan(center[2], 16)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
