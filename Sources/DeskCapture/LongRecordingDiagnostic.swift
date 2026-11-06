import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
enum LongRecordingDiagnostic {
    static func run(root: URL, preferences: UserDefaults, sourceWindow: SCWindow, phase: (String) -> Void) async throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        guard let seconds = Double(environment["DESKCAPTURE_LONG_RECORDING_SECONDS"] ?? "1800"), seconds.isFinite, (1800...3600).contains(seconds) else { throw CaptureError.message("长时录制诊断时长须为1800–3600秒。") }
        let content = try await CaptureEngine().content()
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            return content.displays.contains { $0.displayID == id }
        }) else { throw CaptureError.message("长时诊断需要可用屏幕。") }
        let recorder = ScreenRecorder(preferences: preferences)
        recorder.fps = 30; recorder.systemAudio = true; recorder.cameraEnabled = environment["DESKCAPTURE_LONG_CAMERA"] != "0"
        recorder.microphone = environment["DESKCAPTURE_LONG_MICROPHONE"] == "1"; recorder.captureShortcuts = false
        let cameraIdentity = recorder.cameraEnabled ? try await DiagnosticCamera.resolve(explicitID: recorder.cameraDeviceID.isEmpty ? nil : recorder.cameraDeviceID) : nil
        if let cameraIdentity { recorder.cameraDeviceID = cameraIdentity.id }
        let monitor = RecordingResourceMonitor(directory: root); monitor.start()
        var saved: URL?, failure: Error?
        recorder.onFinish = { saved = $0 }; recorder.onError = { failure = $0 }
        do {
            phase("long-recording-preparing")
            let bounds = CGRect(x: 0, y: 0, width: min(1920, screen.frame.width), height: min(1080, screen.frame.height))
            try await recorder.start(screen: screen, rect: bounds, content: content, diagnostic: true, window: sourceWindow)
            monitor.setPhase("recording"); phase("long-recording-running")
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < seconds {
                try Task.checkCancellation()
                guard recorder.state == .recording else { throw failure ?? CaptureError.message("长时录制提前停止。") }
                if let event = recorder.cameraStopEvent {
                    monitor.setPhase("camera-interrupted-saving"); phase("long-recording-camera-interrupted")
                    await recorder.stop()
                    let details: [String: Any] = ["requestedSeconds": seconds, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
                        "cameraDevice": cameraIdentity?.report ?? [:], "movie": saved?.path ?? "",
                        "cameraStopMessage": event.message ?? "系统未提供错误说明", "cameraStopDomain": event.domain ?? "none", "cameraStopCode": event.code ?? 0]
                    let data = try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
                    let file = root.appendingPathComponent("long-recording-incomplete-camera.json")
                    try await Task.detached(priority: .utility) { try data.write(to: file, options: .atomic) }.value
                    throw CaptureError.message("长时摄像头中断：\(event.domain ?? "none") / \(event.code ?? 0)，\(event.message ?? "系统未提供错误说明")；已保存屏幕与部分素材，详情：\(file.path)")
                }
                try await Task.sleep(for: .seconds(1))
            }
            monitor.setPhase("saving"); phase("long-recording-saving")
            let finishStart = ProcessInfo.processInfo.systemUptime; await recorder.stop()
            let stopSeconds = ProcessInfo.processInfo.systemUptime - finishStart
            guard let saved else { throw failure ?? CaptureError.message("长时录制没有完成保存。") }
            monitor.setPhase("decoding"); phase("long-recording-decoding")
            let asset = AVURLAsset(url: saved), duration = try await asset.load(.duration).seconds
            guard duration >= seconds - 1 else { throw CaptureError.message("长时录制成片明显短于录制时间。") }
            let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 640, height: 640)
            for moment in [0.2, duration / 2, max(0.2, duration - 0.2)] { _ = try await generator.image(at: CMTime(seconds: moment, preferredTimescale: 600)) }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            var audioRanges: [[String: Double]] = []
            for track in tracks {
                let range = try await track.load(.timeRange)
                audioRanges.append(["startSeconds": range.start.seconds, "durationSeconds": range.duration.seconds])
            }
            var cameraDuration: Double?
            if recorder.cameraEnabled {
                let camera = AVURLAsset(url: RecordingCamera.url(for: saved))
                cameraDuration = try await camera.load(.duration).seconds
                let cameraFrames = AVAssetImageGenerator(asset: camera); cameraFrames.maximumSize = CGSize(width: 320, height: 320)
                for moment in [0.2, duration / 2, max(0.2, duration - 0.2)] { _ = try await cameraFrames.image(at: CMTime(seconds: moment, preferredTimescale: 600)) }
            }
            let trend = try await monitor.finish()
            let trendData = try JSONEncoder().encode(trend)
            let trendObject = try JSONSerialization.jsonObject(with: trendData)
            var result: [String: Any] = ["requestedSeconds": seconds, "sourceScope": "owned-generated-window", "durationSeconds": duration, "stopSeconds": stopSeconds,
                "resources": trendObject, "resourceTrace": root.appendingPathComponent("recording-resource-samples.jsonl").path,
                "audioTrackRanges": audioRanges, "microphoneEnabled": recorder.microphone, "cameraEnabled": recorder.cameraEnabled,
                "sampledVideoPositions": 3, "synchronizationMeasured": false, "energyMeasured": false,
                "coverageLimit": "资源计数仅本进程；轨道时长与三位置解码不能证明音画同步或全片可读；未测独立功耗。",
                "movie": saved.path]
            result["configuredFPS"] = 30
            result["captureSamples"] = recorder.captureStatistics.report
            result["cadence"] = try await RecordedFrameCadence.measure(saved).report
            if let cameraDuration { result["cameraDurationSeconds"] = cameraDuration }
            if let cameraIdentity { result["cameraDevice"] = cameraIdentity.report }
            if let event = recorder.cameraStopEvent {
                result["cameraUnexpectedStop"] = ["message": event.message ?? "系统未提供错误说明", "domain": event.domain ?? "none", "code": event.code ?? 0] as [String: Any]
            }
            if let warning = recorder.warning { result["warning"] = warning }
            if recorder.cameraEnabled && ((cameraDuration ?? 0) < duration - 1 || recorder.cameraStopEvent != nil) {
                let details = root.appendingPathComponent("long-recording-incomplete-camera.json")
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try await Task.detached(priority: .utility) { try data.write(to: details, options: .atomic) }.value
                throw CaptureError.message("摄像头未完整覆盖长时录制：相机\(cameraDuration ?? 0)秒，屏幕\(duration)秒；\(recorder.cameraStopEvent?.message ?? "存在中断或缺失区间")。屏幕与部分素材保留，详情：\(details.path)")
            }
            return result
        } catch {
            if recorder.state == .recording || recorder.state == .paused { await recorder.stop() }
            _ = try? await monitor.finish(); throw error
        }
    }
}
