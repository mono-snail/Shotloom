import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct VideoSection: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var speed = 1.0
    var enabled = true
    var captionID: UUID? = nil
    var valid: Bool { start.isFinite && end.isFinite && speed.isFinite && start >= 0 && end > start && (0.25...4).contains(speed) }
}
struct VideoAdvancedEdit: Codable, Equatable {
    var sections: [VideoSection] = []
    var musicPath: String?
    var musicName: String?
    var musicVolume: Float = 0.18
}

struct VideoAdvancedEditView: View {
    @Binding var edit: VideoAdvancedEdit
    let duration: Double
    let currentTime: () -> Double
    let seek: (Double) -> Void
    var body: some View {
        VideoInspectorGroup(L10n.text("片段与变速"), grid: false) {
            VideoControlGrid {
                VideoField(title: L10n.text("当前片段")) {
                    Button(L10n.text("添加 5 秒")) {
                        let start = min(max(0, currentTime()), max(0, duration - 0.1))
                        edit.sections.append(VideoSection(start: start, end: min(duration, start + 5)))
                    }
                }
                VideoField(title: L10n.text("整个视频")) { Button(L10n.text("添加整段")) { edit.sections.append(VideoSection(start: 0, end: duration)) } }
            }
            ForEach($edit.sections) { $section in
                VideoControlGrid {
                    VideoField(title: L10n.text("开始时间（秒）")) { TextField(L10n.text("起点"), value: $section.start, format: .number.precision(.fractionLength(0...2))) }
                    VideoField(title: L10n.text("结束时间（秒）")) { TextField(L10n.text("终点"), value: $section.end, format: .number.precision(.fractionLength(0...2))) }
                    Toggle(L10n.text("保留片段"), isOn: $section.enabled)
                    VideoField(title: L10n.text("播放速度")) {
                        Picker(L10n.text("速度"), selection: $section.speed) { ForEach([0.5, 1, 1.5, 2, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }
                    }
                    VideoField(title: L10n.text("片段顺序")) {
                        HStack {
                            Button { move(section.id, by: -1) } label: { Image(systemName: "arrow.up") }.help(L10n.text("前移片段"))
                            Button { move(section.id, by: 1) } label: { Image(systemName: "arrow.down") }.help(L10n.text("后移片段"))
                        }
                    }
                    VideoField(title: L10n.text("片段操作")) {
                        HStack {
                            Button { seek(section.start) } label: { Image(systemName: "play") }.help(L10n.text("定位片段"))
                            Button { edit.sections.removeAll { $0.id == section.id } } label: { Image(systemName: "trash") }.help(L10n.text("删除片段"))
                        }
                    }
                }
                if !section.valid || section.end > duration {
                    Text(L10n.text("请修正时间范围，终点不能超过原片。")).foregroundStyle(.red)
                }
            }
        }.font(.system(size: 14)).buttonStyle(StudioButtonStyle(command: true)).textFieldStyle(.roundedBorder)
    }
    private func move(_ id: UUID, by amount: Int) {
        guard let index = edit.sections.firstIndex(where: { $0.id == id }), edit.sections.indices.contains(index + amount) else { return }
        edit.sections.swapAt(index, index + amount)
    }
}

struct VideoMusicEditor: View {
    @Binding var edit: VideoAdvancedEdit
    @State private var error: String?
    @State private var importing = false
    @State private var active = false
    @State private var importTask: Task<Void, Never>?
    var body: some View {
        VideoInspectorGroup(L10n.text("背景音乐"), initiallyExpanded: true, grid: false) {
            VideoControlGrid {
                VideoField(title: L10n.text("背景音乐")) { Button(edit.musicPath == nil ? L10n.text("添加音频…") : L10n.text("更换音频…")) { importMusic() } }
                if edit.musicPath != nil {
                    InspectorSlider(title: L10n.text("音乐音量"), value: Binding(get: { Double(edit.musicVolume) }, set: { edit.musicVolume = Float($0) }), range: 0...1, scale: 100, unit: "%")
                    VideoField(title: L10n.text("音乐文件")) { Text(edit.musicName ?? L10n.text("已添加")).lineLimit(1).help(edit.musicName ?? "") }
                    VideoField(title: L10n.text("音乐操作")) { Button(L10n.text("移除音乐")) { edit.musicPath = nil; edit.musicName = nil } }
                }
            }
            if importing { ProgressView(L10n.text("正在导入音频…")).controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red) }
        }.disabled(importing)
            .onAppear { active = true }
            .onDisappear { active = false; importTask?.cancel() }
    }
    private func importMusic() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard active, result == .OK, let source = panel.url else { return }
            let directory = RecordingLibrary.directory.deletingLastPathComponent().appendingPathComponent("RecordingAssets", isDirectory: true)
            let target = directory.appendingPathComponent("music-\(UUID()).\(source.pathExtension)")
            importing = true; error = nil
            importTask = Task { @MainActor in
                var committed = false
                defer {
                    importing = false; importTask = nil
                    if !committed { Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: target) } }
                }
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 200_000_000 else {
                            throw CaptureError.message(L10n.text("音频大于 200 MB，请先压缩。"))
                        }
                        guard !(try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)).isEmpty else {
                            throw CaptureError.message(L10n.text("所选文件没有可用音轨。"))
                        }
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: source, to: target)
                        try Task.checkCancellation()
                    }
                    try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    guard active else { return }
                    edit.musicPath = target.path; edit.musicName = source.lastPathComponent
                    committed = true
                } catch is CancellationError { }
                catch { if active { self.error = error.localizedDescription } }
            }
        }
    }
}
