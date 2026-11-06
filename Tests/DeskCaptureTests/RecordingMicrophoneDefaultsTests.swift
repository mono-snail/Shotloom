import XCTest
@testable import DeskCapture

final class RecordingMicrophoneDefaultsTests: XCTestCase {
    @MainActor
    func testRestoredCameraRecordingEnablesSpeechDespiteLegacyScreenMute() {
        let name = "DeskCapture-camera-speech-\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set(true, forKey: "recordCamera")
        preferences.set(false, forKey: "recordMicrophone")

        let recorder = ScreenRecorder(preferences: preferences)
        XCTAssertTrue(recorder.cameraEnabled)
        XCTAssertTrue(recorder.microphone)
        XCTAssertFalse(preferences.bool(forKey: "recordMicrophone"))
        XCTAssertNil(preferences.object(forKey: "recordCameraMicrophone"))
    }

    @MainActor
    func testExplicitCameraMuteSurvivesRelaunchAndModeChanges() {
        let name = "DeskCapture-camera-mute-\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set(true, forKey: "recordCamera")
        preferences.set(true, forKey: "recordMicrophone")
        let recorder = ScreenRecorder(preferences: preferences)
        recorder.microphone = false

        XCTAssertFalse(ScreenRecorder(preferences: preferences).microphone)
        recorder.cameraEnabled = false
        XCTAssertTrue(recorder.microphone)
        recorder.cameraEnabled = true
        XCTAssertFalse(recorder.microphone)
    }

    @MainActor
    func testScreenMuteStaysIndependentWhenCameraIsEnabled() {
        let name = "DeskCapture-screen-mute-\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set(false, forKey: "recordMicrophone")
        let recorder = ScreenRecorder(preferences: preferences)
        XCTAssertFalse(recorder.microphone)
        recorder.cameraEnabled = true
        XCTAssertTrue(recorder.microphone)
        recorder.cameraEnabled = false
        XCTAssertFalse(recorder.microphone)
    }
}
