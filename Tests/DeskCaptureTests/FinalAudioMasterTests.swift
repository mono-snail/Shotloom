import XCTest
import AVFoundation
@testable import DeskCapture

final class FinalAudioMasterTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-final-audio-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    private func tone(_ output: URL, seconds: Double, amplitude: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        let total = Int((seconds * 48000).rounded())
        for start in stride(from: 0, to: total, by: 4800) {
            let count = min(4800, total - start); buffer.frameLength = AVAudioFrameCount(count)
            let pointer = try XCTUnwrap(buffer.mutableAudioBufferList.pointee.mBuffers.mData).assumingMemoryBound(to: Float.self)
            for index in 0..<count {
                let value = amplitude * Float(sin(Double(start + index) * 2 * .pi * 1000 / 48000))
                pointer[index * 2] = value; pointer[index * 2 + 1] = -value
            }
            try file.write(from: buffer)
        }
    }
    private func movie(_ output: URL) async throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
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
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600)); input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
    func testFloatingMixKeepsOverFullSamplesChannelPhaseAndTimelineGaps() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tone.wav"), output = root.appendingPathComponent("mix.f32")
        try tone(source, seconds: 1, amplitude: 0.75)
        let asset = AVURLAsset(url: source)
        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(sourceTracks.first)
        let composition = AVMutableComposition()
        for _ in 0..<2 {
            let destination = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(.init(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48000)), of: track, at: CMTime(seconds: 1, preferredTimescale: 48000))
        }
        let tracks = composition.tracks(withMediaType: .audio)
        try await Task.detached { try AudioMixPCM.write(composition, tracks: tracks, mix: nil, duration: 3, to: output) }.value
        let bytes = try Data(contentsOf: output); XCTAssertEqual(bytes.count, 3 * 48000 * 8)
        var peak: Float = 0, channelError: Float = 0, gapPeak: Float = 0
        bytes.withUnsafeBytes { raw in
            for frame in 0..<(3 * 48000) {
                let left = raw.loadUnaligned(fromByteOffset: frame * 8, as: Float.self), right = raw.loadUnaligned(fromByteOffset: frame * 8 + 4, as: Float.self)
                channelError = max(channelError, abs(left + right))
                if frame < 48000 || frame >= 96000 { gapPeak = max(gapPeak, abs(left)) }
                peak = max(peak, abs(left))
            }
        }
        XCTAssertLessThan(channelError, 0.0001); XCTAssertLessThan(gapPeak, 0.0001)
        XCTAssertGreaterThan(peak, 1.4) // A clipped integer/AAC intermediate fails this check.
    }
    func testMeterModeMatchesCalibratedSineAndProducesNoAudioCopy() async throws {
        let engine = try XCTUnwrap(VoiceAudioProcessor.runtime, "Build the bundled voice runtime before final unified tests")
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("sine.f32"), output = root.appendingPathComponent("unused.f32"), report = root.appendingPathComponent("report.json")
        let sampleCount = 4 * 48000 * 2
        let radiansPerFrame = 2.0 * Double.pi * 1000.0 / 48000.0
        var samples: [Float] = []; samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount { samples.append(Float(sin(Double(index / 2) * radiansPerFrame) * 0.1)) }
        let bytes = samples.withUnsafeBytes { Data($0) }; try bytes.write(to: input)
        try await Task.detached {
            try LocalSpeechTranscriber.execute(engine, arguments: [input.path, output.path, report.path, "0", "measure", "-16", "-1", "0"], directory: root, context: "test meter")
        }.value
        let value = try JSONDecoder().decode(VoiceAudioReport.self, from: Data(contentsOf: report)); try value.validate()
        XCTAssertEqual(try XCTUnwrap(value.outputLUFS), -20, accuracy: 0.2)
        XCTAssertEqual(value.truePeak, 0.1, accuracy: 0.005)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertEqual(try Data(contentsOf: input), bytes)
    }
    func testMusicOnlyFinalAACIsMeasuredBeforeReplacingDestinationAndFailureKeepsIt() async throws {
        _ = try XCTUnwrap(VoiceAudioProcessor.runtime, "Bundled final audio runtime is required")
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4"), music = root.appendingPathComponent("music.wav"), output = root.appendingPathComponent("result.mp4")
        try await movie(source); try tone(music, seconds: 2, amplitude: 0.9)
        var options = RecordingEffectsOptions(); options.smartZoom = false; options.background = false; options.clicks = false; options.shortcuts = false; options.camera.enabled = false; options.outputFPS = 10; options.maximumDimension = 64
        var edit = VideoAdvancedEdit(); edit.musicPath = music.path; edit.musicVolume = 1; options.edit = edit
        var voice = VoiceAudioOptions(); voice.loudness = true; voice.targetLUFS = -18; voice.ceilingDBTP = -1; options.audio.voice = voice
        let sentinel = Data("existing destination".utf8); try sentinel.write(to: output)
        try await RecordingEffectsExporter.export(source, to: output, options: options)
        let asset = AVURLAsset(url: output), tracks = try await asset.loadTracks(withMediaType: .audio), pcm = root.appendingPathComponent("decoded.f32")
        XCTAssertEqual(tracks.count, 1)
        let meter = try await Task.detached {
            try AudioMixPCM.write(asset, tracks: tracks, mix: nil, duration: 2, to: pcm)
            return try VoiceAudioProcessor.measureRawPCM(pcm)
        }.value
        XCTAssertTrue(FinalAudioMaster.acceptable(meter.truePeak, ceilingDBTP: -1))
        XCTAssertEqual(try XCTUnwrap(meter.outputLUFS), -18, accuracy: 0.4)
        let valid = try Data(contentsOf: output)
        options.edit?.musicPath = root.appendingPathComponent("missing.wav").path
        do { try await RecordingEffectsExporter.export(source, to: output, options: options); XCTFail("Missing music accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: output), valid)
    }
    func testPeakCorrectionAddsMarginAndRejectsInvalidMeasurement() throws {
        XCTAssertFalse(FinalAudioMaster.acceptable(1.0, ceilingDBTP: -1))
        XCTAssertTrue(FinalAudioMaster.acceptable(0, ceilingDBTP: -1))
        XCTAssertFalse(FinalAudioMaster.acceptable(.nan, ceilingDBTP: -1))
        XCTAssertEqual(try FinalAudioMaster.correctionDB(peak: 1, ceilingDBTP: -1), -1.25, accuracy: 0.0001)
        XCTAssertThrowsError(try FinalAudioMaster.correctionDB(peak: .infinity, ceilingDBTP: -1))
    }
}
