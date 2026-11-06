import XCTest
import AppKit
import AVFoundation
import CoreImage
@testable import DeskCapture

final class StudioTests: XCTestCase {
    func testManualLensEasesAndFollowsDeletedTimeline() throws {
        let cue = RecordingLens(start: 1, end: 3, x: 0.8, y: 0.7, zoom: 3)
        XCTAssertEqual(RecordingLens.motion(at: 1, lenses: [cue])?.0, 1)
        XCTAssertEqual(RecordingLens.motion(at: 2, lenses: [cue])?.0, 3)
        XCTAssertNil(RecordingLens.motion(at: 3, lenses: [cue]))
        let plan = try VideoEditPlan(duration: 5, start: 0, end: 5, captions: [CaptionSegment(start: 1.5, end: 2, text: "cut", keep: false)])
        let mapped = RecordingLens.mapped([cue], plan: plan)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertEqual(mapped[1].start, 1.5); XCTAssertEqual(mapped[1].end, 2.5)
        XCTAssertFalse(RecordingLens(start: .nan, end: 3).valid)
    }
    func testAudioCleanupKeepsDurationAndRejectsClipping() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input.caf"), output = dir.appendingPathComponent("output.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for i in 0..<24000 { buffer.floatChannelData![0][i] = 0.3 + 0.2 * sin(Float(i) * 2 * .pi * 1000 / 48000) }
        do { let file = try AVAudioFile(forWriting: input, settings: format.settings); try file.write(from: buffer) }
        var options = RecordingAudioOptions(); options.normalize = true; options.cleanup = true
        try RecordingAudioProcessor.processFile(input, to: output, options: options)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, 24000)
        try file.read(into: buffer)
        let samples = (8000..<Int(buffer.frameLength)).map { buffer.floatChannelData![0][$0] }
        XCTAssertLessThan(abs(samples.reduce(0, +) / Float(samples.count)), 0.01, "DC/low-frequency noise must be removed")
        XCTAssertLessThan(samples.map(abs).max()!, 0.981)
        XCTAssertGreaterThan(samples.map(abs).max()!, 0.15, "Speech-band signal must remain")
    }
    func testCameraCompositeStaysInsideCanvasAndPreservesBackground() throws {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        let original = CIImage(color: .white).cropped(to: canvas)
        let camera = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        var options = CameraOverlayOptions(); options.width = 0.3; options.x = 1; options.y = 1; options.shape = .circle
        let output = CameraFrameCache.composite(camera, over: original, canvas: canvas, options: options)
        let image = try XCTUnwrap(CIContext().createCGImage(output, from: canvas))
        XCTAssertEqual(image.width, 400); XCTAssertEqual(image.height, 300)
        XCTAssertEqual(CapturePixelColor.hex(image, at: CGPoint(x: 10, y: 150)), "#FFFFFF")
        // CGImage rows start at the top: the circle is in the top-right corner.
        XCTAssertEqual(CapturePixelColor.hex(image, at: CGPoint(x: 340, y: 60)), "#FF0000")
    }
    func testStudioProjectPersistsAndRejectsInvalidLenses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: RecordingStudioProject.url(for: url)) }
        var effects = RecordingEffectsOptions(); effects.camera.shape = .circle; effects.audio.cleanup = true; effects.layout = .portrait
        try RecordingStudioProject(lenses: [RecordingLens(start: 0, end: 2), RecordingLens(start: 4, end: 2)], effects: effects).save(url)
        let loaded = RecordingStudioProject.load(url)
        XCTAssertEqual(loaded.lenses.count, 1)
        XCTAssertEqual(loaded.effects?.camera.shape, .circle); XCTAssertEqual(loaded.effects?.audio.cleanup, true)
    }
    func testRecordingLibrarySeparatesCameraAndSortsRecoverySegmentsNumerically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = dir.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["segment-10.mp4", "segment-2.mp4", "camera-segment-0.mov", "DeskCapture-test.camera.mp4"] { try Data([0]).write(to: folder.appendingPathComponent(name)) }
        let entry = try XCTUnwrap(RecordingLibrary.entries(directory: dir).first)
        XCTAssertNil(entry.video)
        XCTAssertEqual(entry.segments.map(\.lastPathComponent), ["segment-2.mp4", "segment-10.mp4"])
    }
    func testCancelledExportPreservesExistingDestination() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("keep.mp4"), sentinel = Data("existing content".utf8)
        try sentinel.write(to: output)
        let asset = AVMutableComposition()
        let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
        let task = Task { try await VideoExport.export(session, to: output, as: .mp4) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export should throw") } catch {}
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count, 1)
    }
}
