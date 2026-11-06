import XCTest
import AVFoundation
@testable import DeskCapture

final class RecordingSourceAudioTests: XCTestCase {
    func testPerSourceGainDoesNotMuteTheOtherSource() throws {
        let asset = AVMutableComposition()
        let system = try XCTUnwrap(asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let microphone = try XCTUnwrap(asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        for track in [system, microphone] { track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))) }
        let mix = RecordingAudioProcessor.mix(tracks: [system, microphone], options: .init(), duration: 3,
                                              sourceVolumes: [system.trackID: 0, microphone.trackID: 0.75])
        for (track, expected) in [(system, Float(0)), (microphone, Float(0.75))] {
            let parameters = try XCTUnwrap(mix.inputParameters.first { $0.trackID == track.trackID })
            var start: Float = -1, end: Float = -1, range = CMTimeRange.zero
            XCTAssertTrue(parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range))
            XCTAssertEqual(start, expected, accuracy: 0.00001)
        }
    }
    func testAudioSettingsRoundTripAndOldProjectsKeepDefaultGains() throws {
        var options = RecordingAudioOptions(); options.sourceVolumes = [0: 0, 1: 0.8]
        XCTAssertEqual(try JSONDecoder().decode(RecordingAudioOptions.self, from: JSONEncoder().encode(options)), options)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        old.removeValue(forKey: "sourceVolumes")
        let restored = try JSONDecoder().decode(RecordingAudioOptions.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.sourceVolumes); XCTAssertEqual(restored.volume, 1)
        for values in [[-1: Float(1)], [0: Float.nan], [128: Float(1)], [0: Float(3)]] {
            options.sourceVolumes = values
            XCTAssertThrowsError(try options.validate())
        }
    }
}
