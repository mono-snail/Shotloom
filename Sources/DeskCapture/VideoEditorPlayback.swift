import AVFoundation
import AppKit
import SwiftUI

final class RecordingPreviewState: @unchecked Sendable {
    private let lock = NSLock()
    private var options: RecordingEffectsOptions
    private var timeline: CameraLayoutTimeline
    init(options: RecordingEffectsOptions, timeline: CameraLayoutTimeline) {
        self.options = options; self.timeline = timeline
    }
    func snapshot() -> (options: RecordingEffectsOptions, timeline: CameraLayoutTimeline) {
        lock.lock(); defer { lock.unlock() }
        return (options, timeline)
    }
    func update(_ options: RecordingEffectsOptions, duration: Double) throws {
        let timeline = try CameraLayoutTimeline(options.cameraLayouts ?? [], duration: duration)
        lock.lock(); defer { lock.unlock() }
        self.options = options; self.timeline = timeline
    }
}

// AVFoundation's immutable composition objects gained Sendable annotations after
// our minimum macOS version. Keep their immutable transfer in one explicit box.
struct RecordingVideoComposition: @unchecked Sendable {
    let value: AVVideoComposition
}

final class RecordingPreviewComposition: @unchecked Sendable {
    let asset: AVComposition
    let initial: AVVideoComposition
    let audioMix: AVAudioMix?
    let sourceAudioTracks: [AVAssetTrack]
    let sourceTrackIndices: [CMPersistentTrackID: Int]
    private let filter: @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void

    init(asset: AVComposition, initial: AVVideoComposition, audioMix: AVAudioMix?, sourceAudioTrackIDs: Set<CMPersistentTrackID>,
         sourceTrackIndices: [CMPersistentTrackID: Int],
         filter: @escaping @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void) {
        self.asset = asset; self.initial = initial; self.audioMix = audioMix; self.filter = filter
        self.sourceTrackIndices = sourceTrackIndices
        self.sourceAudioTracks = asset.tracks(withMediaType: .audio).filter { sourceAudioTrackIDs.contains($0.trackID) }
    }

    func refresh() async throws -> RecordingVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: filter)
        composition.renderSize = initial.renderSize
        composition.frameDuration = initial.frameDuration
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return RecordingVideoComposition(value: composition)
    }
}

/// Keep decoded camera frames and any prepared audio alive for the player item's lifetime.
final class RecordingEffectsPlayback: @unchecked Sendable {
    private(set) var item: AVPlayerItem
    let plan: VideoEditPlan
    let cameraCoverage: CameraFrameCoverage?
    private let camera: CameraFrameCache?
    private let temporaryAudio: URL
    let state: RecordingPreviewState
    let renderer: RecordingPreviewComposition

    init(item: AVPlayerItem, plan: VideoEditPlan, camera: CameraFrameCache?, temporaryAudio: URL,
         state: RecordingPreviewState, renderer: RecordingPreviewComposition, cameraCoverage: CameraFrameCoverage?) {
        self.item = item; self.plan = plan; self.camera = camera; self.temporaryAudio = temporaryAudio
        self.state = state; self.renderer = renderer; self.cameraCoverage = cameraCoverage
    }

    @MainActor
    func useItem(_ item: AVPlayerItem) { self.item = item }

    @MainActor
    func updateAudio(_ options: RecordingAudioOptions) throws {
        try options.validate()
        let audioTracks = renderer.sourceAudioTracks
        let volumes = renderer.sourceTrackIndices.mapValues { options.sourceVolumes?[$0] ?? 1 }
        let mix = RecordingAudioProcessor.mix(tracks: audioTracks, options: options, duration: plan.duration, sourceVolumes: volumes).mutableCopy() as! AVMutableAudioMix
        let sourceIDs = Set(audioTracks.map(\.trackID))
        // Keep music gain, fades and ducking separate from source audio gain.
        mix.inputParameters += (renderer.audioMix?.inputParameters ?? []).filter { !sourceIDs.contains($0.trackID) }
        item.audioMix = mix
    }

    deinit {
        let camera = camera, directory = temporaryAudio
        Task.detached(priority: .utility) {
            await camera?.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

extension VideoEditPlan {
    /// If a source moment was removed, seek to the next retained frame instead.
    func editedTime(for sourceTime: Double) -> Double {
        var offset = 0.0
        for (range, rate) in zip(ranges, rates) {
            if sourceTime < range.start.seconds { return offset }
            if sourceTime < range.end.seconds { return offset + (sourceTime - range.start.seconds) / rate }
            offset += range.duration.seconds / rate
        }
        return max(0, offset - 1.0 / 60)
    }
}

@MainActor
final class VideoEditorPlaybackController: ObservableObject {
    @Published private(set) var player = AVPlayer()
    let presentationLayer = CALayer()
    private var videoLayer: AVPlayerLayer?
    private var transition = UUID()
    private var transportRevision = 0
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var failure: String?
    private var observer: Any?
    private var observerPlayer: AVPlayer?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var wantsPlayback = false
    @Published private(set) var isSeeking = false
    @Published private(set) var isWaiting = false
    private var pendingSeek: Double?
    private var seekTask: Task<Void, Never>?
    private var seekGeneration = UUID()

    init() {
        presentationLayer.backgroundColor = NSColor.black.cgColor
        observePlayer()
    }

    private func observePlayer() {
        let observedPlayer = player
        observerPlayer = observedPlayer
        observedPlayer.automaticallyWaitsToMinimizeStalling = false
        observer = observedPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self, weak observedPlayer] time in
            Task { @MainActor [weak self, weak observedPlayer] in
                guard let self, let observedPlayer, player === observedPlayer, !isSeeking else { return }
                position = time.seconds.isFinite ? time.seconds : 0
            }
        }
        timeControlObservation = observedPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak observedPlayer] _, _ in
            Task { @MainActor [weak self, weak observedPlayer] in
                guard let self, let observedPlayer, player === observedPlayer else { return }
                isWaiting = wantsPlayback && observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        if let item = observedPlayer.currentItem {
            itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, player.currentItem === item, item.status == .failed else { return }
                    pause()
                    failure = item.error?.localizedDescription ?? L10n.text("视频画面无法播放，请重试预览。")
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, player.currentItem === item, !isSeeking,
                          item.duration.seconds.isFinite, player.currentTime().seconds >= item.duration.seconds - 0.05 else { return }
                    wantsPlayback = false; isPlaying = false; isWaiting = false
                }
            }
        }
    }

    private func removeObservers() {
        if let observer { observerPlayer?.removeTimeObserver(observer); self.observer = nil }
        timeControlObservation = nil; itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        observerPlayer = nil
    }

    private func cancelSeeking() {
        seekGeneration = UUID(); pendingSeek = nil
        seekTask?.cancel(); seekTask = nil
        player.currentItem?.cancelPendingSeeks()
        isSeeking = false
    }

    /// Decode into a second layer while the current frame remains visible.
    /// Item readiness alone is insufficient: wait for the layer's first frame.
    func present(_ item: AVPlayerItem, at requestedPosition: () -> Double, onCommit: () -> Void = {}) async throws {
        let token = UUID()
        transition = token
        let candidate = AVPlayer(playerItem: item)
        candidate.isMuted = true
        candidate.automaticallyWaitsToMinimizeStalling = false
        let layer = AVPlayerLayer(player: candidate)
        layer.videoGravity = .resizeAspect
        layer.frame = presentationLayer.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.opacity = 0
        presentationLayer.addSublayer(layer)
        var committed = false
        defer {
            if !committed { candidate.pause(); layer.removeFromSuperlayer(); layer.player = nil }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while item.status != .readyToPlay {
            try Task.checkCancellation()
            guard transition == token else { throw CancellationError() }
            if item.status == .failed { throw item.error ?? CaptureError.message(L10n.text("视频预览准备失败。")) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message(L10n.text("视频预览准备超时，请重试。")) }
            try await Task.sleep(for: .milliseconds(16))
        }
        var seconds = 0.0
        var seekRevision: Int
        repeat {
            try Task.checkCancellation()
            guard transition == token else { throw CancellationError() }
            seekRevision = transportRevision
            let requested = requestedPosition()
            let duration = item.duration.seconds
            seconds = max(0, requested.isFinite ? requested : 0)
            if duration.isFinite { seconds = min(seconds, max(0, duration - 1.0 / 60)) }
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            let sought = await withTaskCancellationHandler {
                await candidate.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            } onCancel: { item.cancelPendingSeeks() }
            try Task.checkCancellation()
            guard sought else { throw CaptureError.message(L10n.text("无法定位视频预览。")) }
            while !layer.isReadyForDisplay {
                try Task.checkCancellation()
                guard transition == token else { throw CancellationError() }
                if item.status == .failed { throw item.error ?? CaptureError.message(L10n.text("视频预览解码失败。")) }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message(L10n.text("视频首帧准备超时，请重试。")) }
                try await Task.sleep(for: .milliseconds(16))
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CaptureError.message(L10n.text("视频预览定位超时，请重试。")) }
        } while seekRevision != transportRevision
        try Task.checkCancellation()
        guard transition == token else { throw CancellationError() }
        let resume = wantsPlayback
        cancelSeeking()
        player.pause()
        removeObservers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        videoLayer?.removeFromSuperlayer()
        videoLayer?.player = nil
        videoLayer = layer
        CATransaction.commit()
        player = candidate
        onCommit()
        candidate.isMuted = false
        position = max(0, seconds); isPlaying = resume; failure = nil
        observePlayer()
        if resume { candidate.play() }
        committed = true
    }

    func stop() {
        transition = UUID(); transportRevision += 1
        wantsPlayback = false; cancelSeeking(); removeObservers()
        player.pause(); player.replaceCurrentItem(with: nil)
        videoLayer?.removeFromSuperlayer(); videoLayer?.player = nil; videoLayer = nil
        position = 0; isPlaying = false; isWaiting = false; failure = nil
    }

    func pause() {
        transportRevision += 1
        wantsPlayback = false; isPlaying = false; isWaiting = false
        player.pause()
    }

    func toggle() {
        guard player.currentItem != nil else { return }
        transportRevision += 1
        if wantsPlayback { pause(); return }
        wantsPlayback = true; isPlaying = true
        if let duration = player.currentItem?.duration.seconds, duration.isFinite, position >= duration - 0.05 {
            seek(0, resume: true)
        } else if !isSeeking { player.play() }
    }

    /// A seek preserves the user's play/pause intent unless explicitly overridden.
    /// AVPlayer seeks are serialized: drag updates replace the pending destination
    /// rather than launching many overlapping exact-frame decodes.
    func seek(_ seconds: Double, resume: Bool? = nil) {
        guard seconds.isFinite, let item = player.currentItem else { return }
        transportRevision += 1
        if let resume { wantsPlayback = resume }
        let duration = item.duration.seconds
        let target = max(0, duration.isFinite ? min(seconds, max(0, duration - 1.0 / 600)) : seconds)
        position = target; pendingSeek = target; isPlaying = wantsPlayback
        player.pause(); isWaiting = false; isSeeking = true
        guard seekTask == nil else { return }
        let token = UUID(); seekGeneration = token
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let seekingPlayer = player
            while let target = pendingSeek {
                pendingSeek = nil
                let finished = await withTaskCancellationHandler {
                    await seekingPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                } onCancel: { item.cancelPendingSeeks() }
                guard !Task.isCancelled, seekGeneration == token, player === seekingPlayer, player.currentItem === item else { return }
                if !finished, pendingSeek == nil {
                    pause(); failure = item.error?.localizedDescription ?? L10n.text("无法定位此处画面，请重新选择位置。")
                }
            }
            guard seekGeneration == token else { return }
            seekTask = nil; isSeeking = false
            if wantsPlayback { seekingPlayer.play() }
        }
    }

    deinit {
        seekTask?.cancel()
        if let observer { observerPlayer?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

/// One source timeline: two trim handles and a separate playhead in the same track.
struct VideoTrimTimeline: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let position: Double
    var trimSeek: ((Double) -> Void)? = nil
    let seek: (Double) -> Void

    private func timestamp(_ value: Double) -> String {
        String(format: "%02d:%04.1f", Int(max(0, value)) / 60, max(0, value).truncatingRemainder(dividingBy: 60))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(L10n.text("起点 \(timestamp(start))"))
                Spacer()
                Text(L10n.text("保留 \(timestamp(max(0, end - start)))")).foregroundStyle(Palette.ice)
                Spacer()
                Text(L10n.text("终点 \(timestamp(end))"))
            }.font(.system(size: 11)).monospacedDigit()
            GeometryReader { geometry in
                let inset = 9.0, width = max(1, geometry.size.width - inset * 2)
                let total = max(0.1, duration)
                let left = inset + width * start / total, right = inset + width * end / total
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(Palette.muted.opacity(0.15))
                        .frame(height: 36).offset(y: 5)
                    Rectangle().fill(Palette.ice.opacity(0.16))
                        .frame(width: max(0, right - left), height: 36).offset(x: left, y: 5)
                    Rectangle().strokeBorder(Palette.ice, lineWidth: 1)
                        .frame(width: max(0, right - left), height: 36).offset(x: left, y: 5)
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            seek(min(duration, max(0, (value.location.x - inset) / width * total)))
                        })
                    Rectangle().fill(Palette.white).frame(width: 2, height: 46)
                        .offset(x: inset + width * min(1, max(0, position / total)) - 1)
                        .allowsHitTesting(false)
                    handle(L10n.text("裁剪起点"), value: start, at: left) { value in
                        start = min(max(0, value), max(0, end - 0.1)); (trimSeek ?? seek)(start)
                    } drag: { location in
                        start = min(max(0, (location - inset) / width * total), max(0, end - 0.1)); (trimSeek ?? seek)(start)
                    }
                    handle(L10n.text("裁剪终点"), value: end, at: right) { value in
                        end = min(duration, max(start + 0.1, value)); (trimSeek ?? seek)(max(start, end - 1.0 / 30))
                    } drag: { location in
                        end = min(duration, max(start + 0.1, (location - inset) / width * total)); (trimSeek ?? seek)(max(start, end - 1.0 / 30))
                    }
                }.coordinateSpace(name: "videoTrimTrack")
            }.frame(height: 46)
            HStack {
                Spacer()
                Text(L10n.text("原片 \(timestamp(duration))"))
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.disabled(duration < 0.1)
    }

    private func handle(_ title: String, value: Double, at x: Double,
                        adjust: @escaping (Double) -> Void, drag: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Palette.ice)
            .overlay { Image(systemName: "line.3.vertical").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.onAccent) }
            .frame(width: 18, height: 40).offset(x: x - 9, y: 3)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("videoTrimTrack"))
                .onChanged { drag($0.location.x) })
            .focusable()
            .onKeyPress(.leftArrow) { adjust(value - 0.1); return .handled }
            .onKeyPress(.rightArrow) { adjust(value + 0.1); return .handled }
            .accessibilityElement().accessibilityLabel(title).accessibilityValue(timestamp(value))
            .accessibilityAdjustableAction { direction in
                adjust(value + (direction == .increment ? 0.1 : -0.1))
            }
            .help(title)
    }
}
