import XCTest
import AVFoundation
import CryptoKit
@testable import DeskCapture

final class LocalSpeechConversionTests: XCTestCase {
    func testActualAACPartialTailConvertsToReadableMonoPCMWithoutLosingTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-speech-conversion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // Include the exact 176,000-frame tail that failed in the signed UI,
        // plus stereo downmixing and sample-rate conversion with partial tails.
        for (index, fixture) in [(16000.0, 1, 176000), (44100.0, 2, 50142), (48000.0, 2, 10439)].enumerated() {
            let (rate, channels, count) = fixture
            let source = root.appendingPathComponent("source-\(index).caf")
            let compressed = root.appendingPathComponent("source-\(index).m4a")
            let output = root.appendingPathComponent("output-\(index).wav")
            try tone(source, rate: rate, channels: AVAudioChannelCount(channels), count: count)
            let asset = AVURLAsset(url: source)
            let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
            try await VideoExport.export(session, to: compressed, as: .m4a)
            let originalHash = SHA256.hash(data: try Data(contentsOf: compressed))
            let decoded = try AVAudioFile(forReading: compressed)
            let expectedFrames = Double(decoded.length) * 16000 / decoded.processingFormat.sampleRate
            try await Task.detached { try LocalSpeechTranscriber.convert(compressed, to: output) }.value
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: compressed)), originalHash)
            let result = try AVAudioFile(forReading: output)
            XCTAssertEqual(result.fileFormat.sampleRate, 16000)
            XCTAssertEqual(result.fileFormat.channelCount, 1)
            XCTAssertEqual(result.fileFormat.commonFormat, .pcmFormatInt16)
            XCTAssertEqual(Double(result.length), expectedFrames, accuracy: 2, "Tail must drain without EOF failure or silent truncation")
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length)))
            try result.read(into: buffer, frameCount: AVAudioFrameCount(result.length))
            XCTAssertEqual(Int64(buffer.frameLength), result.length)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            let tailCount = min(1024, Int(buffer.frameLength))
            let energy = (Int(buffer.frameLength) - tailCount..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) }
            XCTAssertGreaterThan(sqrt(energy / Double(tailCount)), 0.10, "Last partial buffer must contain the source tone")
        }
    }

    private func tone(_ url: URL, rate: Double, channels: AVAudioChannelCount, count: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        for start in stride(from: 0, to: count, by: 4096) {
            let size = min(4096, count - start); buffer.frameLength = AVAudioFrameCount(size)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(channels) {
                for i in 0..<size { data[channel][i] = 0.25 * Float(sin(Double(start + i) * 2 * .pi * 1000 / rate)) }
            }
            try file.write(from: buffer)
        }
    }
}
