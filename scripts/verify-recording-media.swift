import Foundation
import AVFoundation
import CoreVideo
import CryptoKit

// Compile with swiftc -parse-as-library. Read-only, bounded-memory verification
// of a diagnostic recording; output is an independent JSON report.
private struct TrackReport: Encodable {
    var kind: String
    var trackID: Int32
    var buffers: Int = 0
    var samples: Int64 = 0
    var firstPTS: Double?
    var lastPTS: Double?
    var decodedEnd: Double?
    var largestPTSGap: Double = 0
    var nonmonotonicBuffers: Int = 0
}

private struct MediaReport: Encodable {
    let schema = 1
    var success: Bool
    var input: String
    var inputSHA256: String?
    var durationSeconds: Double?
    var elapsedSeconds: Double
    var tracks: [TrackReport]
    var error: String?
    let coverage = "All decoded video/audio buffers; one buffer retained at a time. Does not establish visual correctness, synchronization, energy use, or absence of future defects."
}

private func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private enum VerificationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

private func decode(_ asset: AVURLAsset, track: AVAssetTrack, kind: String) throws -> TrackReport {
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = kind == "video"
        ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        : [AVFormatIDKey: kAudioFormatLinearPCM,
           AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
           AVLinearPCMIsNonInterleaved: false]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw VerificationError.invalid("Cannot add \(kind) decoder") }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? VerificationError.invalid("Cannot start \(kind) decoder")
    }
    var report = TrackReport(kind: kind, trackID: track.trackID)
    while true {
        try Task.checkCancellation()
        let found = try autoreleasepool { () throws -> Bool in
            guard let buffer = output.copyNextSampleBuffer() else { return false }
            guard CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
                  CMSampleBufferGetNumSamples(buffer) > 0 else {
                throw VerificationError.invalid("Invalid or empty decoded \(kind) buffer")
            }
            if kind == "video" {
                guard let image = CMSampleBufferGetImageBuffer(buffer),
                      CVPixelBufferGetWidth(image) > 0, CVPixelBufferGetHeight(image) > 0 else {
                    throw VerificationError.invalid("Decoded video has no image")
                }
            } else {
                guard let block = CMSampleBufferGetDataBuffer(buffer),
                      CMBlockBufferGetDataLength(block) > 0 else {
                    throw VerificationError.invalid("Decoded audio has no PCM data")
                }
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard pts.isFinite else { throw VerificationError.invalid("Nonfinite \(kind) timestamp") }
            if let previous = report.lastPTS {
                if pts < previous - 0.000001 { report.nonmonotonicBuffers += 1 }
                report.largestPTSGap = max(report.largestPTSGap, pts - previous)
            }
            if report.firstPTS == nil { report.firstPTS = pts }
            report.lastPTS = pts
            let duration = CMSampleBufferGetDuration(buffer).seconds
            let end = pts + (duration.isFinite && duration >= 0 ? duration : 0)
            report.decodedEnd = max(report.decodedEnd ?? end, end)
            report.buffers += 1
            report.samples += Int64(CMSampleBufferGetNumSamples(buffer))
            return true
        }
        if !found { break }
    }
    guard reader.status == .completed else {
        throw reader.error ?? VerificationError.invalid("\(kind) decoder stopped before completion")
    }
    guard report.buffers > 0, report.nonmonotonicBuffers == 0 else {
        throw VerificationError.invalid("Empty or nonmonotonic \(kind) track \(track.trackID)")
    }
    return report
}

@main private struct VerifyRecordingMedia {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: verify-recording-media INPUT OUTPUT.json\n".utf8))
            exit(2)
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
            FileHandle.standardError.write(Data("Report must not replace its input.\n".utf8)); exit(2)
        }
        let started = ProcessInfo.processInfo.systemUptime
        var report = MediaReport(success: false, input: input.path, elapsedSeconds: 0, tracks: [])
        do {
            guard try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw VerificationError.invalid("Input must be a regular media file")
            }
            report.inputSHA256 = try digest(input)
            let asset = AVURLAsset(url: input)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw VerificationError.invalid("Invalid media duration") }
            report.durationSeconds = duration
            for kind in [AVMediaType.video, .audio] {
                for track in try await asset.loadTracks(withMediaType: kind) {
                    report.tracks.append(try decode(asset, track: track, kind: kind == .video ? "video" : "audio"))
                }
            }
            guard report.tracks.contains(where: { $0.kind == "video" }) else {
                throw VerificationError.invalid("No video track")
            }
            guard try digest(input) == report.inputSHA256 else {
                throw VerificationError.invalid("Input changed during verification")
            }
            report.success = true
        } catch { report.error = error.localizedDescription }
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Cannot write report: \(error.localizedDescription)\n".utf8)); exit(2)
        }
        print("Full media decode: \(report.success ? "passed" : "failed"), \(report.tracks.count) tracks")
        exit(report.success ? 0 : 1)
    }
}
