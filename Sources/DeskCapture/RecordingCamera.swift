import AppKit
import AVFoundation
import CoreImage
import Vision
import SwiftUI

final class RecordingCamera: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    // Connect once, before recording. Mounting a HUD must not reconfigure the capture graph.
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let queue = DispatchQueue(label: "DeskCapture.camera", qos: .userInitiated)
    private let output = AVCaptureMovieFileOutput()
    private var startWait: CameraOperationWait<Date>?
    private var stopWait: CameraOperationWait<URL>?
    private let preparePermit = CameraOperationPermit()
    private let beginPermit = CameraOperationPermit()
    private let endPermit = CameraOperationPermit()
    private let shutdownPermit = CameraOperationPermit()
    private var pendingURL: URL?
    private var started: Date?
    private var finishResult: Result<URL, Error>?
    private var recoveryLeases: [URL: RecordingSessionLease] = [:]
    struct StopEvent: Sendable { let file: URL; let message: String?; let unexpected: Bool; let domain: String?; let code: Int? }
    private var stopRequested = false
    private var stoppedHandler: (@Sendable (StopEvent) -> Void)?
    func setStoppedHandler(_ handler: @escaping @Sendable (StopEvent) -> Void) { queue.async { self.stoppedHandler = handler } }
    static func url(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("camera.mp4") }

    func prepare(deviceID: String?, audioDeviceID: String? = nil) async throws {
        try Task.checkCancellation()
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureError.message(L10n.text("摄像头未授权；可以关闭画中画继续录屏。")) }
        if audioDeviceID != nil {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.message(L10n.text("音频输入未授权，请在系统设置的隐私与安全性中允许麦克风访问，或选择不录声音。")) }
        }
        try Task.checkCancellation()
        guard preparePermit.enter() else { throw CaptureError.message(L10n.text("视频源仍在处理上次请求；未重复提交设备操作。")) }
        let waiting = CameraOperationWait<Void>()
        try await waiting.value(timeout: 10, message: L10n.text("视频源准备超过10秒；原请求仍由后台收尾，未换用其他设备。"), start: {
            self.queue.async {
                defer { self.preparePermit.leave() }
                guard waiting.pending else { return }
                do {
                    guard !self.output.isRecording, self.startWait == nil, self.stopWait == nil,
                          self.pendingURL == nil || self.finishResult != nil else { throw CaptureError.message(L10n.text("旧视频源仍在收尾，原始文件保持。")) }
                    try self.configure(deviceID: deviceID, audioDeviceID: audioDeviceID)
                    if self.previewLayer.session !== self.session { self.previewLayer.session = self.session }
                    guard waiting.pending else { self.session.stopRunning(); return }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw CaptureError.message(L10n.text("所选视频源未能启动。")) }
                    if !waiting.resolve(.success(())) { self.session.stopRunning() }
                } catch { waiting.resolve(.failure(error)); self.session.stopRunning() }
            }
        })
    }
    private func configure(deviceID: String?, audioDeviceID: String?) throws {
        let selected = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
        guard let device = deviceID == nil ? AVCaptureDevice.default(for: .video) : selected,
              device.isConnected else { throw CaptureError.message(L10n.text("所选视频源已断开，未切换到其他设备。")) }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for old in session.outputs { session.removeOutput(old) }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        else if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        let input = try AVCaptureDeviceInput(device: device)
        for port in input.ports where port.mediaType == .audio {
            port.isEnabled = audioDeviceID == device.uniqueID
        }
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.message(L10n.text("摄像头正在被占用或无法启动。")) }
        session.addInput(input)
        // A muxed USB source may expose audio on the video input itself.
        // Otherwise connect only the explicitly selected audio device.
        if let audioDeviceID {
            if audioDeviceID != device.uniqueID {
                guard let audioDevice = AVCaptureDevice(uniqueID: audioDeviceID), audioDevice.isConnected else {
                    throw CaptureError.message(L10n.text("所选音频源不可用，请刷新并重新选择；未换用其他麦克风。"))
                }
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                for port in audioInput.ports where port.mediaType != .audio { port.isEnabled = false }
                guard audioInput.ports.contains(where: { $0.mediaType == .audio }), session.canAddInput(audioInput) else {
                    throw CaptureError.message(L10n.text("无法接入所选音频源，请选择可用的音频输入。"))
                }
                session.addInput(audioInput)
            } else if !input.ports.contains(where: { $0.mediaType == .audio }) {
                throw CaptureError.message(L10n.text("所选视频设备未提供音频输入。请在声音来源中选择该设备的独立音频输入、麦克风，或不录声音。"))
            }
        }
        session.addOutput(output)
        if audioDeviceID == nil {
            output.connection(with: .audio)?.isEnabled = false
        } else {
            guard let audio = output.connection(with: .audio) else {
                throw CaptureError.message(L10n.text("无法建立录音连接，未开始无声录制。"))
            }
            audio.isEnabled = true
        }
        output.maxRecordedFileSize = 0; output.minFreeDiskSpaceLimit = 256_000_000
        output.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    }
    func begin(_ url: URL, recoveryLease: RecordingSessionLease? = nil) async throws -> Date {
        try Task.checkCancellation()
        guard beginPermit.enter() else { throw CaptureError.message(L10n.text("视频源启动调用尚未返回，未重复提交。")) }
        let waiting = CameraOperationWait<Date>()
        return try await waiting.value(timeout: 10, message: L10n.text("摄像头启动超时；原片与会话占用状态保留。"), onAbandon: { [weak self, weak waiting] in
            guard let self, let waiting else { return }
            self.queue.async {
                guard self.startWait === waiting else { return }
                self.startWait = nil; self.stopRequested = true; self.output.stopRecording()
            }
        }, start: {
            self.queue.async {
                defer { self.beginPermit.leave() }
                guard waiting.pending else { return }
                guard !self.output.isRecording, self.startWait == nil, self.stopWait == nil, self.session.isRunning,
                      self.pendingURL == nil || self.finishResult != nil else { waiting.resolve(.failure(CaptureError.message(L10n.text("视频源仍在收尾或尚未准备完成。")))); return }
                guard url.isFileURL, ["mov", "mp4"].contains(url.pathExtension.lowercased()), !FileManager.default.fileExists(atPath: url.path),
                      self.output.connection(with: .video)?.isEnabled == true else { waiting.resolve(.failure(CaptureError.message(L10n.text("视频源连接不可用或目标文件已存在，未覆盖。")))); return }
                self.stopRequested = false
                self.pendingURL = url; self.started = nil; self.finishResult = nil; self.startWait = waiting
                if let recoveryLease { self.recoveryLeases[url] = recoveryLease }
                self.output.startRecording(to: url, recordingDelegate: self)
            }
        })
    }
    func end() async throws -> URL {
        try Task.checkCancellation()
        guard endPermit.enter() else { throw CaptureError.message(L10n.text("视频源停止调用尚未返回，未重复提交。")) }
        let waiting = CameraOperationWait<URL>()
        return try await waiting.value(timeout: 15, message: L10n.text("摄像头文件写入超时；原片和占用锁保留到实际收尾。"), onAbandon: { [weak self, weak waiting] in
            guard let self, let waiting else { return }
            self.queue.async { if self.stopWait === waiting { self.stopWait = nil } }
        }, start: {
            self.queue.async {
                defer { self.endPermit.leave() }
                guard waiting.pending else {
                    self.stopRequested = true
                    if self.output.isRecording { self.output.stopRecording() }
                    self.session.stopRunning(); return
                }
                if let result = self.finishResult { waiting.resolve(result); return }
                guard self.pendingURL != nil, self.stopWait == nil else { waiting.resolve(.failure(CaptureError.message(L10n.text("视频源没有片段或正在完成停止请求。")))); return }
                self.stopRequested = true; self.stopWait = waiting; self.output.stopRecording()
            }
        })
    }
    func shutdown() {
        guard shutdownPermit.enter() else { return }
        queue.async {
            defer { self.shutdownPermit.leave() }
            self.startWait?.resolve(.failure(CancellationError())); self.startWait = nil
            if self.output.isRecording { self.stopRequested = true; self.output.stopRecording() }
            self.session.stopRunning()
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            guard self.pendingURL == fileURL else { return }
            let date = Date(); self.started = date
            let waiting = self.startWait; self.startWait = nil
            if waiting?.resolve(.success(date)) != true { self.stopRequested = true; self.output.stopRecording() }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.recoveryLeases.removeValue(forKey: fileURL)
            guard self.pendingURL == fileURL else { return }
            let success = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            let result: Result<URL, Error> = error == nil || success ? .success(fileURL) : .failure(error!)
            self.finishResult = result; self.stopWait?.resolve(result); self.stopWait = nil
            self.startWait?.resolve(.failure(error ?? CaptureError.message(L10n.text("摄像头没有产生可用画面。")))); self.startWait = nil
            self.stoppedHandler?(.init(file: fileURL, message: error?.localizedDescription, unexpected: !self.stopRequested,
                                       domain: (error as NSError?)?.domain, code: (error as NSError?)?.code))
        }
    }
}

struct CameraRecordingSegment {
    let url: URL?
    let offset: Double
    let duration: Double
    static func join(_ segments: [Self], to output: URL, microphoneSources: [URL] = [], audioSources: [String]? = nil) async throws {
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.message(L10n.text("无法创建摄像头轨道。")) }
        var time = CMTime.zero, hasFrames = false
        var sourceAssets: [AVURLAsset] = []
        defer { withExtendedLifetime(sourceAssets) {} }
        for segment in segments {
            guard segment.duration.isFinite, segment.duration > 0, segment.duration <= 1_000_000, segment.offset.isFinite, segment.offset >= 0, segment.offset <= 1_000_000, time.seconds + segment.duration <= 1_000_000 else { throw CaptureError.message(L10n.text("摄像头片段时间范围无效。")) }
            try Task.checkCancellation()
            let length = CMTime(seconds: segment.duration, preferredTimescale: 600)
            let asset = segment.url.map { AVURLAsset(url: $0) }
            if let asset { sourceAssets.append(asset) }
            if let asset, let track = try await asset.loadTracks(withMediaType: .video).first {
                let requested = CMTimeRange(start: CMTime(seconds: segment.offset, preferredTimescale: 600), duration: length)
                let available = CMTimeRangeGetIntersection(requested, otherRange: try await track.load(.timeRange))
                if available.duration.isNumeric && available.duration > .zero {
                    hasFrames = true
                    let prefix = max(.zero, available.start - requested.start)
                    if prefix > .zero { target.insertEmptyTimeRange(.init(start: time, duration: prefix)) }
                    try target.insertTimeRange(available, of: track, at: time + prefix)
                    let tail = length - prefix - available.duration
                    if tail > .zero { target.insertEmptyTimeRange(.init(start: time + prefix + available.duration, duration: tail)) }
                } else { target.insertEmptyTimeRange(.init(start: time, duration: length)) }
                target.preferredTransform = try await track.load(.preferredTransform)
            } else { target.insertEmptyTimeRange(CMTimeRange(start: time, duration: length)) }
            time = time + length
        }
        // The microphone is captured by ScreenCaptureKit on the screen timeline.
        // Copy its explicitly recorded microphone role, without applying the camera's
        // startup offset or losing speech during a camera interruption.
        var audioTime = CMTime.zero
        var microphone: AVMutableCompositionTrack?
        for url in microphoneSources {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url); sourceAssets.append(asset)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration > .zero,
                  !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { continue }
            guard audioTime < time else { break }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            var copiedMicrophone = false
            for (index, track) in tracks.enumerated() {
                // These roles come from this session's writer configuration,
                // never from guessing the channels/order of imported media.
                var isMicrophone = audioSources?.count == tracks.count && audioSources?[index] == "microphone"
                let metadata = try await track.load(.metadata)
                for item in metadata where item.commonKey == .commonKeyTitle {
                    let title = try await item.load(.stringValue)
                    if title == "DeskCapture Microphone" { isMicrophone = true; break }
                    if title == "DeskCapture System Audio" { isMicrophone = false; break }
                }
                guard isMicrophone else { continue }
                if microphone == nil {
                    microphone = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                guard let microphone else { throw CaptureError.message(L10n.text("无法创建摄像头麦克风音轨。")) }
                let requested = CMTimeRange(start: .zero, duration: min(duration, max(.zero, time - audioTime)))
                let available = CMTimeRangeGetIntersection(requested, otherRange: try await track.load(.timeRange))
                if available.duration.isNumeric && available.duration > .zero {
                    try microphone.insertTimeRange(available, of: track, at: audioTime + available.start)
                    copiedMicrophone = true
                }
                break
            }
            if audioSources?.contains("microphone") == true && !copiedMicrophone {
                throw CaptureError.message(L10n.text("麦克风未产生可用音轨，未导出静音摄像头原片；屏幕视频和录制分段已保留。"))
            }
            audioTime = audioTime + duration
        }
        guard hasFrames, let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw CaptureError.message(L10n.text("没有可合并的摄像头画面，原片与已有目标保留。")) }
        export.timeRange = .init(start: .zero, duration: time)
        try await VideoExport.export(export, to: output, as: .mp4)
    }
}

enum CameraOverlayShape: String, Codable, CaseIterable, Identifiable {
    case rounded, circle, cutout
    var id: String { rawValue }
    var title: String { switch self { case .rounded: L10n.text("圆角"); case .circle: L10n.text("圆形"); case .cutout: L10n.text("人像抠像") } }
}
struct CameraOverlayOptions: Codable, Equatable {
    var enabled = true
    var x = 0.85
    var y = 0.82
    var width = 0.22
    var mirrored = true
    var shape: CameraOverlayShape = .rounded
}

/// Empty camera edit ranges remain empty; never invent frames for an interrupted recording.
struct CameraFrameCoverage: Sendable {
    let ranges: [CMTimeRange]
    func contains(_ seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        return ranges.contains { CMTimeRangeContainsTime($0, time: time) }
    }
    static func load(_ asset: AVAsset) async throws -> Self {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.message(L10n.text("摄像头素材没有视频轨道。"))
        }
        let ranges = try await track.load(.segments).filter {
            !$0.isEmpty && $0.timeMapping.target.isValid && $0.timeMapping.target.duration > .zero
        }.map { $0.timeMapping.target }
        guard !ranges.isEmpty else { throw CaptureError.message(L10n.text("摄像头素材没有可显示的画面。")) }
        return Self(ranges: ranges)
    }
}

actor CameraFrameCache {
    struct Sample: Sendable { let image: CIImage; let time: Double }
    private let asset: AVURLAsset
    private var coverage: CameraFrameCoverage?
    private var track: AVAssetTrack?
    private var transform = CGAffineTransform.identity
    private var frameDuration = 1.0 / 30
    private var frames: [Int: Sample] = [:]
    private var order: [Int] = []
    private let removeBackground: Bool
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private var cancelled = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var readerRange: CMTimeRange?
    private var previousBuffer: CMSampleBuffer?
    private var nextBuffer: CMSampleBuffer?
    private var lastRequested = -Double.infinity

    init(url: URL, removeBackground: Bool) {
        asset = AVURLAsset(url: url)
        self.removeBackground = removeBackground
        segmentation.qualityLevel = .balanced; segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    func availableFrames() async throws -> CameraFrameCoverage {
        if let coverage { return coverage }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.message(L10n.text("摄像头素材没有视频轨道。"))
        }
        let loaded = try await CameraFrameCoverage.load(asset)
        let matrix = try await video.load(.preferredTransform)
        let interval = (try? await video.load(.minFrameDuration))?.seconds
        let fps = (try? await video.load(.nominalFrameRate)) ?? 30
        guard !cancelled else { throw CancellationError() }
        guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].allSatisfy(\.isFinite),
              abs(matrix.a * matrix.d - matrix.b * matrix.c) > 0.000001 else {
            throw CaptureError.message(L10n.text("摄像头画面方向信息无效。"))
        }
        if let interval, interval.isFinite, interval > 0 { frameDuration = interval }
        else if fps.isFinite, fps > 0 { frameDuration = 1 / Double(fps) }
        track = video; transform = matrix; coverage = loaded
        return loaded
    }
    func sample(at time: Double) async throws -> Sample? {
        guard !cancelled else { throw CancellationError() }
        try Task.checkCancellation()
        guard time.isFinite, time >= 0, time <= 1_000_000 else { return nil }
        let coverage = try await availableFrames()
        guard !cancelled else { throw CancellationError() }
        guard coverage.contains(time) else { return nil }
        let key = max(0, Int(time * (removeBackground ? 12 : 24)))
        if let frame = frames[key] { return frame }
        // No suspension from this point through the cache commit. The actor
        // really serializes decoder access, unlike awaiting image(at:) on a
        // shared AVAssetImageGenerator for every composition request.
        return try autoreleasepool {
            guard let decoded = try decode(at: time, coverage: coverage) else { return nil }
            var frame = CIImage(cvPixelBuffer: decoded.buffer).transformed(by: transform)
            guard !frame.extent.isEmpty, !frame.extent.isInfinite,
                  [frame.extent.minX, frame.extent.minY, frame.extent.width, frame.extent.height].allSatisfy(\.isFinite) else {
                throw CaptureError.message(L10n.text("摄像头画面尺寸无效。"))
            }
            frame = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
            let scale = min(1, 1024 / max(frame.extent.width, frame.extent.height))
            if scale < 1 { frame = frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            guard let cg = context.createCGImage(frame, from: frame.extent) else {
                throw CaptureError.message(L10n.text("无法生成摄像头预览画面。"))
            }
            frame = CIImage(cgImage: cg)
            if removeBackground {
                try Task.checkCancellation()
                try VNImageRequestHandler(cgImage: cg).perform([segmentation])
                if let buffer = segmentation.results?.first?.pixelBuffer {
                    let mask = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: frame.extent.width / CGFloat(CVPixelBufferGetWidth(buffer)), y: frame.extent.height / CGFloat(CVPixelBufferGetHeight(buffer))))
                    frame = frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame.extent), kCIInputMaskImageKey: mask])
                }
            }
            try Task.checkCancellation()
            // Release decoder-owned pixel buffers and lazy CI graphs before caching.
            guard let flattened = context.createCGImage(frame, from: frame.extent) else {
                throw CaptureError.message(L10n.text("无法缓存摄像头预览画面。"))
            }
            let result = Sample(image: CIImage(cgImage: flattened), time: decoded.time)
            if order.count >= 12 { frames.removeValue(forKey: order.removeFirst()) }
            frames[key] = result; order.append(key); return result
        }
    }

    private func decode(at seconds: Double, coverage: CameraFrameCoverage) throws -> (buffer: CVPixelBuffer, time: Double)? {
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        guard let range = coverage.ranges.first(where: { CMTimeRangeContainsTime($0, time: time) }), let track else { return nil }
        if output == nil || readerRange.map({ !CMTimeRangeEqual($0, range) }) != false
            || seconds < lastRequested - 0.000001 || seconds > lastRequested + 2 {
            resetReader()
            let candidate = try AVAssetReader(asset: asset)
            let stream = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            stream.alwaysCopiesSampleData = false
            guard candidate.canAdd(stream) else { throw CaptureError.message(L10n.text("无法建立摄像头解码通道。")) }
            candidate.add(stream)
            let start = max(range.start, CMTime(seconds: max(0, seconds - 0.15), preferredTimescale: 60000))
            candidate.timeRange = CMTimeRange(start: start, end: range.end)
            guard candidate.startReading() else { throw candidate.error ?? CaptureError.message(L10n.text("摄像头视频无法解码。")) }
            reader = candidate; output = stream; readerRange = range
            nextBuffer = try readNext()
        }
        lastRequested = seconds
        while let next = nextBuffer {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(next).seconds
            guard pts.isFinite else { throw CaptureError.message(L10n.text("摄像头帧时间无效。")) }
            if pts > seconds + 0.000001 { break }
            previousBuffer = next
            nextBuffer = try readNext()
        }
        if let previous = previousBuffer {
            let pts = CMSampleBufferGetPresentationTimeStamp(previous).seconds
            let duration = CMSampleBufferGetDuration(previous).seconds
            let exposure = duration.isFinite && duration > 0 ? duration : frameDuration
            // Do not freeze the last face over an empty edit or a prematurely
            // ended camera recording. Screen playback can continue without it.
            guard seconds < pts + exposure + 1.0 / 600 else { return nil }
            guard let buffer = CMSampleBufferGetImageBuffer(previous) else { return nil }
            return (buffer, pts)
        }
        // Some files start a fraction of a frame after their declared range.
        if let next = nextBuffer {
            let pts = CMSampleBufferGetPresentationTimeStamp(next).seconds
            if pts - seconds <= 0.07, let buffer = CMSampleBufferGetImageBuffer(next) { return (buffer, pts) }
        }
        return nil
    }
    private func readNext() throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        let buffer = output?.copyNextSampleBuffer()
        if reader?.status == .failed { throw reader?.error ?? CaptureError.message(L10n.text("摄像头画面读取失败。")) }
        return buffer
    }
    private func resetReader() {
        reader?.cancelReading(); reader = nil; output = nil; readerRange = nil
        previousBuffer = nil; nextBuffer = nil; lastRequested = -Double.infinity
    }
    func cancel() { cancelled = true; resetReader(); frames = [:]; order = []; coverage = nil; track = nil }
    nonisolated static func composite(_ frame: CIImage, over image: CIImage, canvas: CGRect, options: CameraOverlayOptions) -> CIImage {
        guard let timeline = try? CameraLayoutTimeline([], duration: 1) else { return image }
        let pose = timeline.pose(at: 0, canvas: canvas.size, camera: frame.extent.size, options: options)
        return CameraLayoutTimeline.composite(frame, screen: image, canvas: canvas, pose: pose, options: options)
    }
}

struct CameraLivePreview: NSViewRepresentable {
    let camera: RecordingCamera
    func makeNSView(context: Context) -> NSView {
        CameraPreviewSurface(preview: camera.previewLayer)
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let view = view as? CameraPreviewSurface else { return }
        // A replacement HUD may already have adopted the layer. Never detach its feed.
        if view.preview.superlayer === view.layer { view.preview.removeFromSuperlayer() }
    }
    final class CameraPreviewSurface: NSView {
        let preview: AVCaptureVideoPreviewLayer
        init(preview: AVCaptureVideoPreviewLayer) {
            self.preview = preview
            super.init(frame: .zero)
            wantsLayer = true; preview.videoGravity = .resizeAspectFill
            preview.removeFromSuperlayer(); layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); preview.frame = bounds }
    }
}
