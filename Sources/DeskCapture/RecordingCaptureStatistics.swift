import Foundation

struct RecordingCaptureStatistics {
    private(set) var segments = 0
    private(set) var sourceVideoFrames = 0
    private(set) var writtenVideoFrames = 0
    private(set) var heldVideoFrames = 0
    private(set) var droppedVideo = 0
    private(set) var droppedAudio = 0
    mutating func append(_ result: FragmentedScreenWriter.Result) {
        segments += 1; sourceVideoFrames += result.sourceVideoFrames
        writtenVideoFrames += result.videoFrames; heldVideoFrames += result.heldVideoFrames
        droppedVideo += result.droppedVideo; droppedAudio += result.droppedAudio
    }
    var report: [String: Any] {
        ["segments": segments, "validSourceVideoSamples": sourceVideoFrames, "writtenVideoFrames": writtenVideoFrames,
         "staticHoldFrames": heldVideoFrames, "writerBackpressureDroppedVideo": droppedVideo, "writerBackpressureDroppedAudio": droppedAudio,
         "scope": "accepted complete monotonic ScreenCaptureKit video samples and writer backpressure; not upstream frame-loss proof"]
    }
}
