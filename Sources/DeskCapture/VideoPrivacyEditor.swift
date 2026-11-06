import SwiftUI
import AVFoundation

struct VideoPrivacyEditor: View {
    @Binding var cues: [VideoPrivacyCue]
    let video: URL
    let duration: Double
    let canvasSize: CGSize
    let currentTime: () -> Double
    let seek: (Double) -> Void
    @State private var selected: UUID?
    @State private var referenceTime = 0.0
    @State private var limit = 50
    @State private var error: String?
    var body: some View {
        VideoInspectorGroup(L10n.text("遮盖与高亮"), grid: false) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: addRegion) {
                    Label(L10n.text("添加遮盖区域"), systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }.disabled(duration <= 0 || cues.count >= 500)
                ForEach(Array(cues.suffix(limit).reversed())) { cue in
                    regionEditor(cue)
                }
                if limit < cues.count { Button(L10n.text("再显示50个区域")) { limit += 50 } }
                if let error { Text(error).foregroundStyle(.orange) }
            }.padding(.top, 6)
        }
    }
    private func addRegion() {
        let current = currentTime()
        let time = current.isFinite ? min(max(0, current), max(0, duration - 0.001)) : 0
        let cue = VideoPrivacyCue(start: 0, end: duration)
        do {
            _ = try VideoPrivacyTimeline(cues + [cue], duration: duration)
            cues.append(cue); selected = cue.id; referenceTime = time; error = nil
            seek(time)
            if cues.count > limit { limit = cues.count }
        } catch { self.error = error.localizedDescription }
    }
    private func selectRegion(_ cue: VideoPrivacyCue) {
        let time = currentTime()
        referenceTime = time.isFinite && time >= cue.start && time < cue.end ? time : cue.start
        selected = cue.id
        seek(referenceTime)
    }
    private func rangeTitle(_ cue: VideoPrivacyCue) -> String {
        if cue.start == 0 && abs(cue.end - duration) < 0.001 { return L10n.text("整段视频") }
        return String(format: L10n.text("%.2f–%.2f 秒"), cue.start, cue.end)
    }
    private func regionEditor(_ cue: VideoPrivacyCue) -> some View {
        let number = (cues.firstIndex(where: { $0.id == cue.id }) ?? 0) + 1
        let expanded = selected == cue.id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    if expanded { selected = nil } else { selectRegion(cue) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 12).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("区域 \(number)")).font(.system(size: 13, weight: .semibold))
                            Text(L10n.text("\(cue.kind.title) · \(rangeTitle(cue))"))
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                                .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }.buttonStyle(StudioNavigationStyle(selected: expanded))
                    .accessibilityLabel(L10n.text("区域 \(number)，\(cue.kind.title)，\(rangeTitle(cue))"))
                    .accessibilityValue(expanded ? L10n.text("已展开，正在编辑") : L10n.text("已折叠"))
                StudioIconButton(title: L10n.text("移除区域 \(number)"), symbol: "trash") {
                    cues.removeAll { $0.id == cue.id }
                    if expanded { selected = nil }
                }
            }
            if expanded {
                PrivacyCueControls(
                    cue: Binding(get: { cues.first(where: { $0.id == cue.id }) ?? cue },
                                 set: { updated in
                                     if let index = cues.firstIndex(where: { $0.id == cue.id }) { cues[index] = updated }
                                 }),
                    video: video, canvasSize: canvasSize, regions: cues,
                    referenceTime: referenceTime, duration: duration,
                    selectRegion: { id in
                        if let region = cues.first(where: { $0.id == id }) { selectRegion(region) }
                    }, seek: seek
                ).padding(.horizontal, 8)
            }
            Divider()
        }.accessibilityElement(children: .contain)
    }

}

private struct PrivacyCueControls: View {
    @Binding var cue: VideoPrivacyCue
    let video: URL
    let canvasSize: CGSize
    let regions: [VideoPrivacyCue]
    let referenceTime: Double
    let duration: Double
    let selectRegion: (UUID) -> Void
    let seek: (Double) -> Void
    @State private var image: CGImage?
    @State private var frameError: String?
    @State private var refresh = UUID()
    private var frameTime: Double {
        min(max(referenceTime, cue.start), max(cue.start, cue.end - 0.001))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VideoControlGrid {
                VideoField(title: L10n.text("画面")) { Picker(L10n.text("画面"), selection: $cue.target) { ForEach(VideoPrivacyCue.Target.allCases, id: \.self) { Text($0.title).tag($0) } } }
                VideoField(title: L10n.text("处理方式")) { Picker(L10n.text("处理"), selection: $cue.kind) { ForEach(VideoPrivacyCue.Kind.allCases, id: \.self) { Text($0.title).tag($0) } } }
                VideoField(title: L10n.text("开始时间（秒）")) { TextField(L10n.text("开始秒"), value: $cue.start, format: .number) }
                VideoField(title: L10n.text("结束时间（秒）")) { TextField(L10n.text("结束秒"), value: $cue.end, format: .number) }
                VideoField(title: L10n.text("生效范围")) { Button(L10n.text("覆盖整段视频")) { cue.start = 0; cue.end = duration } }
                VideoField(title: L10n.text("参考帧")) { Button(L10n.text("定位并刷新")) { seek(frameTime); refresh = UUID() } }
            }
            selection.frame(height: 210)
                .accessibilityLabel(L10n.text("拖动画框修改当前区域；其他区域以蓝色边框显示"))
            DisclosureGroup(L10n.text("精细调整")) {
                VideoControlGrid {
                    VideoField(title: L10n.text("水平位置")) { TextField("X", value: $cue.x, format: .number) }
                    VideoField(title: L10n.text("垂直位置")) { TextField("Y", value: $cue.y, format: .number) }
                    VideoField(title: L10n.text("区域宽度")) { TextField(L10n.text("宽"), value: $cue.width, format: .number) }
                    VideoField(title: L10n.text("区域高度")) { TextField(L10n.text("高"), value: $cue.height, format: .number) }
                    InspectorSlider(title: L10n.text("安全外扩"), value: $cue.padding, range: 0...0.05, scale: 100, unit: "%", decimals: 1)
                    Toggle(L10n.text("移动至终点"), isOn: Binding(get: { cue.endX != nil }, set: { enabled in cue.endX = enabled ? cue.x : nil; cue.endY = enabled ? cue.y : nil }))
                    if cue.endX != nil {
                        VideoField(title: L10n.text("终点水平位置")) { TextField("X", value: Binding(get: { cue.endX ?? cue.x }, set: { cue.endX = $0 }), format: .number) }
                        VideoField(title: L10n.text("终点垂直位置")) { TextField("Y", value: Binding(get: { cue.endY ?? cue.y }, set: { cue.endY = $0 }), format: .number) }
                    }
                }
            }
            if !cue.valid || cue.end > duration { Text(L10n.text("请修正时间或坐标，结束时间不能超过视频时长，区域必须在画面内。")).foregroundStyle(.orange) }
            if let frameError { Text(frameError).foregroundStyle(.orange) }
        }
        .task(id: "\(cue.target.rawValue)-\(frameTime.bitPattern)-\(refresh)") {
            image = nil; frameError = nil
            guard cue.target != .canvas else { return }
            let input = cue.target == .camera ? RecordingCamera.url(for: video) : video
            let seconds = frameTime
            do {
                guard seconds.isFinite, seconds >= 0 else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
                    generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 960, height: 960)
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    defer { generator.cancelAllCGImageGeneration() }
                    return try await withTaskCancellationHandler(operation: { try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image }, onCancel: { generator.cancelAllCGImageGeneration() })
                }
                let frame = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; image = frame
            } catch { if !Task.isCancelled { frameError = L10n.text("参考帧不可读：\(error.localizedDescription)") } }
        }
    }
    private var selection: some View {
        GeometryReader { geometry in
            let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? canvasSize
            let ratio = max(0.01, size.width / max(1, size.height))
            let width = min(geometry.size.width, geometry.size.height * ratio), height = width / ratio
            let box = CGRect(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2, width: width, height: height)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image { Image(decorative: image, scale: 1).resizable().frame(width: width, height: height).position(x: box.midX, y: box.midY) }
                ForEach(regions.filter { $0.id != cue.id && $0.valid && $0.target == cue.target && $0.start <= frameTime && $0.end >= frameTime }) { other in
                    let rect = other.rect(at: frameTime)
                    Rectangle().fill(other.kind == .opaque ? Color.black.opacity(0.85) : Color.yellow.opacity(0.3))
                        .overlay(Rectangle().stroke(Color.blue, lineWidth: 1))
                        .frame(width: rect.width * width, height: rect.height * height)
                        .position(x: box.minX + rect.midX * width, y: box.minY + (1 - rect.midY) * height)
                        .onTapGesture { selectRegion(other.id) }
                }
                if cue.valid {
                    Rectangle().fill(cue.kind == .opaque ? Color.black.opacity(0.85) : Color.yellow.opacity(0.3))
                        .overlay(Rectangle().stroke(.yellow, lineWidth: 1))
                        .frame(width: cue.width * width, height: cue.height * height)
                        .position(x: box.minX + (cue.x + cue.width / 2) * width, y: box.minY + (1 - cue.y - cue.height / 2) * height)
                }
            }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    func x(_ point: CGPoint) -> Double { min(1, max(0, (point.x - box.minX) / max(1, width))) }
                    func y(_ point: CGPoint) -> Double { min(1, max(0, 1 - (point.y - box.minY) / max(1, height))) }
                    let a = value.startLocation, b = value.location
                    cue.x = min(0.999, min(x(a), x(b))); cue.y = min(0.999, min(y(a), y(b)))
                    cue.width = min(1 - cue.x, max(0.001, abs(x(a) - x(b))))
                    cue.height = min(1 - cue.y, max(0.001, abs(y(a) - y(b))))
                    cue.endX = nil; cue.endY = nil
                })
        }
    }
}
