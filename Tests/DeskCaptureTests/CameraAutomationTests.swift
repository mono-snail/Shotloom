import XCTest
import CoreImage
import AVFoundation
@testable import DeskCapture

final class CameraAutomationTests: XCTestCase {
    func testLargestInitialFaceNearestContinuationAndDelayedSubjectSwitch() {
        var tracker = StableFaceTracker()
        let a = CGRect(x: 0.1, y: 0.38, width: 0.2, height: 0.24), b = CGRect(x: 0.75, y: 0.45, width: 0.1, height: 0.1)
        XCTAssertEqual(tracker.update([a, b], at: 0).x, 0.2, accuracy: 0.0001)
        let largeOther = CGRect(x: 0.65, y: 0.35, width: 0.3, height: 0.3)
        XCTAssertEqual(tracker.update([largeOther, a], at: 0.5).x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(tracker.update([], at: 1).x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(tracker.update([b], at: 1.5).x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(tracker.update([b], at: 2).x, 0.2, accuracy: 0.0001)
        let switched = tracker.update([b], at: 2.5)
        XCTAssertGreaterThan(switched.x, 0.2); XCTAssertLessThanOrEqual(switched.x, 0.325001)
    }
    func testShortPausesUnknownCoverageAndNoAudioDoNotHideCamera() {
        var options = CameraAutomationOptions(); options.hideWhenQuiet = true
        let bins: [Double?] = Array(repeating: -20, count: 10) + Array(repeating: -90, count: 7) + Array(repeating: -20, count: 5) + Array(repeating: -90, count: 30) + [nil, nil]
        var analysis = CameraAutomationAnalysis(); analysis.audioAvailable = true
        analysis.quiet = CameraAutomationAnalysis.quietIntervals(bins, options: options)
        XCTAssertEqual(analysis.quiet.count, 1)
        XCTAssertEqual(analysis.visibility(at: 1.5, options: options), 1)
        XCTAssertEqual(analysis.visibility(at: 4.2, options: options), 0)
        XCTAssertEqual(analysis.visibility(at: 5.5, options: options), 1)
        analysis.audioAvailable = false
        XCTAssertEqual(analysis.visibility(at: 4.2, options: options), 1)
    }
    func testShortQuietTailIsContinuousWhenAudioReturnsBeforeFadeCompletes() {
        var options = CameraAutomationOptions(); options.hideWhenQuiet = true
        let analysis = CameraAutomationAnalysis(quiet: [.init(start: 1.5, end: 1.6)], audioAvailable: true)
        XCTAssertEqual(analysis.visibility(at: 1.6 - 0.000001, options: options), analysis.visibility(at: 1.6, options: options), accuracy: 0.0001)
        XCTAssertGreaterThan(analysis.visibility(at: 1.7, options: options), analysis.visibility(at: 1.6, options: options))
    }
    func testManualVisibilityAndFocusOverrideAutomaticDecisions() throws {
        var options = CameraAutomationOptions(); options.followFace = true; options.hideWhenQuiet = true
        options.overrides = [.init(start: 1, end: 2, visibility: .show, focusX: 0.9, focusY: 0.5), .init(start: 2, end: 3, visibility: .hide)]
        try options.validate(duration: 4)
        let analysis = CameraAutomationAnalysis(quiet: [.init(start: 0, end: 4)], audioAvailable: true)
        XCTAssertEqual(analysis.visibility(at: 1.5, options: options), 1)
        XCTAssertEqual(analysis.visibility(at: 2.5, options: options), 0)
        XCTAssertEqual(analysis.focus(at: 1.5, options: options), CGPoint(x: 0.9, y: 0.5))
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 80))
        options.cropZoom = 2
        let crop = analysis.reframed(image, at: 1.5, options: options)
        XCTAssertEqual(crop.extent, CGRect(x: 0, y: 0, width: 50, height: 40))
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 100, height: 80))
        options.overrides.append(.init(start: 1.5, end: 2.5))
        XCTAssertThrowsError(try options.validate(duration: 4))
    }
    func testStereoOppositePhaseEnergyIsNotMisclassifiedAsQuiet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-camera-auto-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("stereo.caf")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)); buffer.frameLength = 48000
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<48000 {
                let value: Float = frame < 16000 ? Float(sin(Double(frame) * 2 * .pi * 440 / 16000) * 0.1) : 0
                channels[0][frame] = value; channels[1][frame] = -value
            }
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: audio)
        var options = CameraAutomationOptions(); options.hideWhenQuiet = true; options.minimumQuiet = 0.5
        let result = try await CameraAutomationAnalyzer.analyze(source: audio, camera: root.appendingPathComponent("unused.mp4"), duration: 3, options: options)
        XCTAssertTrue(result.audioAvailable)
        XCTAssertEqual(result.visibility(at: 0.5, options: options), 1)
        XCTAssertEqual(result.visibility(at: 2, options: options), 0)
        XCTAssertEqual(try Data(contentsOf: audio), original)
    }
    func testCancelledCameraCacheCannotReturnOldFrames() async {
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-unused-camera-\(UUID()).mp4")
        let cache = CameraFrameCache(url: unused, removeBackground: false)
        await cache.cancel()
        for time in [0.0, .nan] {
            do {
                _ = try await cache.sample(at: time)
                XCTFail("A cancelled cache must reject every request")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected cancellation, received \(error)")
            }
        }
    }
}
