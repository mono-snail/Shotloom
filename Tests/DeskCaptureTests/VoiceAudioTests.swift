import XCTest
@testable import DeskCapture

final class VoiceAudioTests: XCTestCase {
    func testBypassAndNormalizationValidation() throws {
        var audio = RecordingAudioOptions(), voice = VoiceAudioOptions()
        voice.neural = true; audio.voice = voice; XCTAssertTrue(audio.needsProcessing)
        voice.bypass = true; audio.voice = voice; audio.cleanup = true; XCTAssertFalse(audio.needsProcessing)
        voice.bypass = false; voice.loudness = true; audio.voice = voice; audio.normalize = true
        XCTAssertThrowsError(try audio.validate())
        voice.targetLUFS = .nan; XCTAssertThrowsError(try voice.validate())
    }
    func testDuckingAttackHoldReleaseAndDisabledPath() throws {
        let report = VoiceAudioReport(frames: 48000, sampleRate: 48000, inputLUFS: -20, outputLUFS: -16, truePeak: 0.8, gainDB: 4, peakLimited: false, vad: [1, 1, 1, 0, 0, 0, 0, 0, 0, 0])
        try report.validate()
        var options = VoiceAudioOptions(); options.musicDucking = true
        let gains = report.ducking(options: options)
        XCTAssertEqual(gains.count, 11); XCTAssertEqual(gains[0], 1)
        XCTAssertLessThan(gains[2], 0.3); XCTAssertLessThan(gains[5], 0.3)
        XCTAssertGreaterThan(gains[10], gains[6]); XCTAssertTrue(gains.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1 })
        options.bypass = true; XCTAssertTrue(report.ducking(options: options).isEmpty)
    }
    func testPrivatePCMProtocolPassthroughExactLengthAndSourceBytes() async throws {
        guard let engine = VoiceAudioProcessor.runtime else { throw XCTSkip("Built voice engine missing; no native inference claim") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-voice-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.f32"), output = root.appendingPathComponent("output.f32"), reportURL = root.appendingPathComponent("report.json")
        let frames = 4801 // partial final 10 ms frame must survive.
        let values: [Float] = (0..<(frames * 2)).map { Float(sin(Double($0 / 2) * 2 * .pi * 1000 / 48000) * 0.1) }
        let bytes = values.withUnsafeBytes { Data($0) }; try bytes.write(to: input)
        let worker = Task.detached {
            try LocalSpeechTranscriber.execute(engine, arguments: [input.path, output.path, reportURL.path, "0", "0", "-16", "-1", "0"], directory: root, context: "test voice engine")
        }
        try await worker.value
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        let report = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: reportURL)); try report.validate()
        XCTAssertEqual(report.frames, frames); XCTAssertEqual(try Data(contentsOf: input), bytes)
        let neural = Task.detached {
            try LocalSpeechTranscriber.execute(engine, arguments: [input.path, output.path, reportURL.path, "0.75", "0", "-16", "-1", "1"], directory: root, context: "test voice engine")
        }
        try await neural.value
        let processedReport = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: reportURL)); try processedReport.validate()
        XCTAssertEqual(try Data(contentsOf: output).count, bytes.count); XCTAssertEqual(processedReport.frames, frames)
    }
    func testIntegratedLoudnessConvergenceAndSilenceResultWhenEngineAvailable() async throws {
        guard let engine = VoiceAudioProcessor.runtime else { throw XCTSkip("Built voice engine missing; no native meter claim") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-loudness-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.f32"), output = root.appendingPathComponent("output.f32"), reportURL = root.appendingPathComponent("report.json")
        let values: [Float] = (0..<(96000 * 2)).map { Float(sin(Double($0 / 2) * 2 * .pi * 1000 / 48000) * 0.05) }
        try values.withUnsafeBytes { Data($0) }.write(to: input)
        try await Task.detached {
            try LocalSpeechTranscriber.execute(engine, arguments: [input.path, output.path, reportURL.path, "0", "1", "-18", "-1", "0"], directory: root, context: "test loudness")
        }.value
        let report = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: reportURL)); try report.validate()
        XCTAssertEqual(try XCTUnwrap(report.outputLUFS), -18, accuracy: 0.3)
        XCTAssertLessThanOrEqual(report.truePeak, pow(10, -1.0 / 20) + 0.01)
        try Data(count: 96000 * 8).write(to: input)
        try await Task.detached {
            try LocalSpeechTranscriber.execute(engine, arguments: [input.path, output.path, reportURL.path, "0", "1", "-18", "-1", "0"], directory: root, context: "test silence")
        }.value
        let silent = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: reportURL)); try silent.validate()
        XCTAssertNil(silent.outputLUFS); XCTAssertEqual(silent.truePeak, 0)
    }
}
