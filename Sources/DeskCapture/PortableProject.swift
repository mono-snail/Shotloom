import Foundation
import CryptoKit
import Darwin
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

extension UTType {
    static let deskVideoProject = UTType(exportedAs: "com.deskcapture.video-project", conformingTo: .package)
    static let deskTutorialProject = UTType(exportedAs: "com.deskcapture.tutorial-project", conformingTo: .package)
}
struct PortableProjectManifest: Codable {
    enum Kind: String, Codable { case video, tutorial }
    struct Asset: Codable { let file: String; let bytes: Int64; let sha256: String }
    var version = 1
    let kind: Kind
    let entry: String
    var music: String?
    var camera: String?
    var cursorSource: String?
    var assets: [Asset]
}
enum PortableProject {
    private static let manager = FileManager.default
    static func safe(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && !name.hasPrefix(".") && name != "manifest.json" &&
        !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\0") && name == (name as NSString).lastPathComponent
    }
    private static func read(_ file: URL, limit: Int = 16_000_000) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= limit else { throw CaptureError.message(L10n.text("工程文件类型或大小无效：\(file.lastPathComponent)")) }
        return try Data(contentsOf: file)
    }
    static func manifest(_ root: URL) throws -> PortableProjectManifest {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CaptureError.message(L10n.text("项目包不是有效的普通目录。")) }
        let manifest = try JSONDecoder().decode(PortableProjectManifest.self, from: read(root.appendingPathComponent("manifest.json"), limit: 2_000_000))
        let names = manifest.assets.map(\.file)
        guard manifest.version == 1, !names.isEmpty, names.count <= 1000, Set(names).count == names.count,
              names.allSatisfy(safe), names.contains(manifest.entry),
              [manifest.music, manifest.camera, manifest.cursorSource].compactMap({ $0 }).allSatisfy({ names.contains($0) }),
              manifest.assets.allSatisfy({ $0.bytes >= 0 && $0.bytes <= 20_000_000_000 && $0.sha256.count == 64 && $0.sha256.allSatisfy({ $0.isHexDigit }) }),
              manifest.assets.reduce(Int64(0), { $0 + $1.bytes }) <= (manifest.kind == .video ? 20_000_000_000 : 1_000_000_000) else { throw CaptureError.message(L10n.text("项目清单版本、路径、依赖或预算无效。")) }
        let actual = Set(try manager.contentsOfDirectory(atPath: root.path).filter { $0 != ".DS_Store" && $0 != "manifest.json" })
        guard actual == Set(names) else { throw CaptureError.message(L10n.text("项目包缺少文件或含清单外文件。")) }
        if manifest.kind == .video {
            guard ["DeskCapture-project.mp4", "DeskCapture-project.mov", "DeskCapture-project.m4v"].contains(manifest.entry) else { throw CaptureError.message(L10n.text("视频项目入口无效。")) }
            let video = root.appendingPathComponent(manifest.entry)
            var allowed = [manifest.entry, RecordingEditStore.url(for: video).lastPathComponent, RecordingInteractions.url(for: video).lastPathComponent, RecordingDrawingTimeline.url(for: video).lastPathComponent]
            if let camera = manifest.camera { guard camera == RecordingCamera.url(for: video).lastPathComponent else { throw CaptureError.message(L10n.text("摄像头依赖路径不符。")) }; allowed.append(camera) }
            if let cursor = manifest.cursorSource {
                guard cursor == "cursor-source.mp4" else { throw CaptureError.message(L10n.text("光标源依赖路径不符。")) }
                let file = root.appendingPathComponent(cursor); allowed += [cursor, RecordingInteractions.url(for: file).lastPathComponent, RecordingDrawingTimeline.url(for: file).lastPathComponent]
            }
            if let music = manifest.music { allowed.append(music) }
            guard Set(names).isSubset(of: Set(allowed)) else { throw CaptureError.message(L10n.text("项目含不支持的依赖文件。")) }
        } else { guard manifest.entry == "steps.json", names.allSatisfy({ $0 == "steps.json" || $0.hasSuffix(".png") }) else { throw CaptureError.message(L10n.text("教程项目依赖类型无效。")) } }
        return manifest
    }
    private struct SourceStamp {
        let file: URL
        let stat: stat
        func verify() throws {
            var current = Darwin.stat()
            guard lstat(file.path, &current) == 0, current.st_ino == stat.st_ino, current.st_dev == stat.st_dev,
                  current.st_size == stat.st_size, current.st_mtimespec.tv_sec == stat.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == stat.st_mtimespec.tv_nsec else { throw CaptureError.message(L10n.text("打包期间源文件已改变，未提交项目包。")) }
        }
    }
    private final class Builder {
        let root: URL
        let limit: Int64
        var total: Int64 = 0
        var assets: [PortableProjectManifest.Asset] = []
        var sources: [SourceStamp] = []
        init(root: URL, limit: Int64) throws { self.root = root; self.limit = limit; try manager.createDirectory(at: root, withIntermediateDirectories: false) }
        private func reserve(_ name: String, bytes: Int64) throws {
            guard safe(name), assets.count < 1000, !assets.contains(where: { $0.file == name }), bytes >= 0, bytes <= limit - total else { throw CaptureError.message(L10n.text("项目文件名冲突或超过容量预算。")) }
        }
        func write(_ bytes: Data, name: String) throws {
            try reserve(name, bytes: Int64(bytes.count)); try Task.checkCancellation()
            try bytes.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            total += Int64(bytes.count); assets.append(.init(file: name, bytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
        }
        func copy(_ file: URL, name: String, expected: PortableProjectManifest.Asset? = nil) throws {
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw CaptureError.message(L10n.text("项目素材无法打开：\(file.lastPathComponent)")) }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
            var before = Darwin.stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw CaptureError.message(L10n.text("项目素材不是普通文件。")) }
            try reserve(name, bytes: before.st_size)
            if let expected { guard expected.bytes == before.st_size else { throw CaptureError.message(L10n.text("项目素材大小不符：\(name)")) } }
            let target = root.appendingPathComponent(name)
            guard manager.createFile(atPath: target.path, contents: nil) else { throw CaptureError.message(L10n.text("无法创建项目暂存文件。")) }
            let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
            var hash = SHA256(), count: Int64 = 0
            while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation(); count += Int64(bytes.count)
                guard count <= before.st_size else { throw CaptureError.message(L10n.text("项目素材正在增长，未打包。")) }
                hash.update(data: bytes); try output.write(contentsOf: bytes)
            }
            try output.synchronize()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == before.st_size, expected.map({ $0.sha256.lowercased() == digest }) ?? true else { throw CaptureError.message(L10n.text("项目素材校验失败：\(name)")) }
            let stamp = SourceStamp(file: file, stat: before); try stamp.verify(); sources.append(stamp)
            total += count; assets.append(.init(file: name, bytes: count, sha256: digest))
        }
        func finish(_ manifest: PortableProjectManifest, to destination: URL, beforeCommit: (() throws -> Void)?) throws {
            for source in sources { try source.verify() }
            let bytes = try JSONEncoder().encode(manifest); guard bytes.count <= 2_000_000 else { throw CaptureError.message(L10n.text("项目清单超过预算。")) }
            try bytes.write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try beforeCommit?(); try Task.checkCancellation()
            for source in sources { try source.verify() }
            guard !manager.fileExists(atPath: destination.path) else { throw CaptureError.message(L10n.text("项目目标已存在，未覆盖。请选择新名称。")) }
            try manager.moveItem(at: root, to: destination)
        }
    }
    private static func stage(for output: URL) -> URL { output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-project-\(UUID())") }
    static func exportVideo(_ video: URL, snapshot: RecordingEditSnapshot, expected: String, to output: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        guard ["mp4", "mov", "m4v"].contains(video.pathExtension.lowercased()) else { throw CaptureError.message(L10n.text("可编辑视频包支持MP4/MOV/M4V素材。")) }
        try snapshot.validate()
        let dependencies = try ProjectDependencySnapshot.video(video, snapshot: snapshot)
        guard try RecordingEditStore.fingerprint(video) == expected else { throw CaptureError.message(L10n.text("磁盘工程已改变，未打包。")) }
        let stage = stage(for: output); defer { try? manager.removeItem(at: stage) }
        let builder = try Builder(root: stage, limit: 20_000_000_000)
        let name = "DeskCapture-project.\(video.pathExtension.lowercased())", packagedVideo = stage.appendingPathComponent(name)
        try builder.copy(video, name: name)
        var manifest = PortableProjectManifest(kind: .video, entry: name, assets: [])
        let interactionFile = RecordingInteractions.url(for: video)
        if manager.fileExists(atPath: interactionFile.path) {
            var interactions = try JSONDecoder().decode(RecordingInteractions.self, from: read(interactionFile, limit: 32_000_000))
            guard interactions.version == 1, interactions.events.count <= 1_000_000 else { throw CaptureError.message(L10n.text("交互时间轴无效。")) }
            if interactions.editableCursorSource != nil {
                let cursor = try EditableCursorSource.resolve(video, metadata: interactions)
                let cursorName = "cursor-source.mp4", packagedCursor = stage.appendingPathComponent(cursorName)
                try builder.copy(cursor, name: cursorName); manifest.cursorSource = cursorName
                try builder.copy(RecordingInteractions.url(for: cursor), name: RecordingInteractions.url(for: packagedCursor).lastPathComponent)
                let drawing = RecordingDrawingTimeline.url(for: cursor)
                if manager.fileExists(atPath: drawing.path) { try builder.copy(drawing, name: RecordingDrawingTimeline.url(for: packagedCursor).lastPathComponent) }
                interactions.editableCursorSource = cursorName
            }
            try builder.write(JSONEncoder().encode(interactions), name: RecordingInteractions.url(for: packagedVideo).lastPathComponent)
        } else if snapshot.studio.effects?.cursor?.active == true { throw CaptureError.message(L10n.text("缺少可编辑光标素材，未打包。")) }
        let camera = RecordingCamera.url(for: video), drawing = RecordingDrawingTimeline.url(for: video)
        if manager.fileExists(atPath: camera.path) { let name = RecordingCamera.url(for: packagedVideo).lastPathComponent; try builder.copy(camera, name: name); manifest.camera = name }
        if manager.fileExists(atPath: drawing.path) { try builder.copy(drawing, name: RecordingDrawingTimeline.url(for: packagedVideo).lastPathComponent) }
        var snapshot = snapshot
        if let music = snapshot.studio.effects?.edit?.musicPath {
            let file = URL(fileURLWithPath: music), suffix = file.pathExtension.lowercased()
            guard !suffix.isEmpty, suffix.count <= 10, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw CaptureError.message(L10n.text("音乐素材扩展名无效。")) }
            let name = "music.\(suffix)"; try builder.copy(file, name: name); manifest.music = name
            snapshot.studio.effects?.edit?.musicPath = "deskcapture-package:music"
        }
        try builder.write(JSONEncoder().encode(snapshot), name: RecordingEditStore.url(for: packagedVideo).lastPathComponent)
        guard try RecordingEditStore.fingerprint(video) == expected else { throw CaptureError.message(L10n.text("打包期间工程已改变，未提交。")) }
        manifest.assets = builder.assets; try validateTimelines(stage, manifest: manifest); try builder.finish(manifest, to: output, beforeCommit: {
            try beforeCommit?(); try dependencies.verify()
            guard try RecordingEditStore.fingerprint(video) == expected else { throw CaptureError.message(L10n.text("提交前工程已改变，未打包。")) }
        })
    }
    static func exportTutorial(_ steps: [TutorialStep], directory: URL, to output: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        try TutorialEditing.validate(steps)
        let stage = stage(for: output); defer { try? manager.removeItem(at: stage) }
        let builder = try Builder(root: stage, limit: 1_000_000_000)
        for file in Set(steps.flatMap { TutorialEditing.frames($0).map(\.file) }) { try TutorialEditing.validateImage(directory.appendingPathComponent(file)); try builder.copy(directory.appendingPathComponent(file), name: file) }
        try builder.write(JSONEncoder().encode(steps), name: "steps.json")
        try builder.finish(.init(kind: .tutorial, entry: "steps.json", assets: builder.assets), to: output, beforeCommit: beforeCommit)
    }
    struct Restored { let kind: PortableProjectManifest.Kind; let directory: URL; let video: URL?; let steps: [TutorialStep]? }
    static func restore(_ input: URL, in managedRoot: URL) async throws -> Restored {
        let manifest = try await Task.detached(priority: .userInitiated) { try Self.manifest(input) }.value
        let destination = managedRoot.appendingPathComponent(UUID().uuidString), stage = stage(for: destination)
        let preparing = Task.detached(priority: .userInitiated) { () throws -> (RecordingEditSnapshot?, [TutorialStep]?) in
            try manager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
            let builder = try Builder(root: stage, limit: manifest.kind == .video ? 20_000_000_000 : 1_000_000_000)
            do {
                for asset in manifest.assets { try builder.copy(input.appendingPathComponent(asset.file), name: asset.file, expected: asset) }
                for source in builder.sources { try source.verify() }
                if manifest.kind == .video {
                    try validateTimelines(stage, manifest: manifest)
                    guard ["mp4", "mov", "m4v"].contains((manifest.entry as NSString).pathExtension.lowercased()),
                          let snapshot = try RecordingEditStore.load(stage.appendingPathComponent(manifest.entry)) else { throw CaptureError.message(L10n.text("缺少有效视频编辑设置。")) }
                    return (snapshot, nil)
                }
                guard manifest.entry == "steps.json" else { throw CaptureError.message(L10n.text("教程入口无效。")) }
                let steps = try JSONDecoder().decode([TutorialStep].self, from: read(stage.appendingPathComponent("steps.json"), limit: 2_000_000))
                try TutorialEditing.validate(steps)
                for file in Set(steps.flatMap { TutorialEditing.frames($0).map(\.file) }) {
                    guard manifest.assets.contains(where: { $0.file == file }) else { throw CaptureError.message(L10n.text("教程缺少图片依赖。")) }
                    try TutorialEditing.validateImage(stage.appendingPathComponent(file))
                }
                return (nil, steps)
            } catch { try? manager.removeItem(at: stage); throw error }
        }
        do {
            let loaded = try await withTaskCancellationHandler(operation: { try await preparing.value }, onCancel: { preparing.cancel() })
            if manifest.kind == .video {
                for name in [Optional(manifest.entry), manifest.camera, manifest.cursorSource].compactMap({ $0 }) {
                    let asset = AVURLAsset(url: stage.appendingPathComponent(name))
                    let seconds = try await asset.load(.duration).seconds
                    guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty, seconds.isFinite, seconds > 0 else { throw CaptureError.message(L10n.text("项目视频素材不可读或没有视频轨。")) }
                    let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 128, height: 128)
                    defer { generator.cancelAllCGImageGeneration() }
                    _ = try await withTaskCancellationHandler(operation: { try await generator.image(at: CMTime(seconds: seconds / 2, preferredTimescale: 600)) }, onCancel: { generator.cancelAllCGImageGeneration() })
                    if name == manifest.entry, let snapshot = loaded.0 {
                        guard snapshot.captions.allSatisfy({ $0.end <= seconds + 0.01 }), (snapshot.studio.trimEnd ?? seconds) <= seconds + 0.01 else { throw CaptureError.message(L10n.text("项目字幕或裁剪范围超出素材时长。")) }
                        if let options = snapshot.studio.effects {
                            _ = try CameraLayoutTimeline(options.cameraLayouts ?? [], duration: seconds)
                            _ = try VideoPrivacyTimeline(options.privacy ?? [], duration: seconds)
                            try (options.cursor ?? .init()).validate(duration: seconds)
                            try (options.cameraAutomation ?? .init()).validate(duration: seconds)
                        }
                    }
                }
                if let name = manifest.music { guard !(try await AVURLAsset(url: stage.appendingPathComponent(name)).loadTracks(withMediaType: .audio)).isEmpty else { throw CaptureError.message(L10n.text("项目音乐素材没有音轨。")) } }
            }
            let committing = Task.detached(priority: .userInitiated) {
                if var snapshot = loaded.0 {
                    if let path = snapshot.studio.effects?.edit?.musicPath {
                        guard path == "deskcapture-package:music", let music = manifest.music else { throw CaptureError.message(L10n.text("项目引用外部音乐路径，未打开。")) }
                        snapshot.studio.effects?.edit?.musicPath = destination.appendingPathComponent(music).path
                    }
                    let video = stage.appendingPathComponent(manifest.entry)
                    _ = try RecordingEditStore.save(snapshot, for: video, expected: RecordingEditStore.fingerprint(video))
                    if let metadata = RecordingInteractions.load(video), metadata.editableCursorSource != nil { _ = try EditableCursorSource.resolve(video, metadata: metadata) }
                }
                try Task.checkCancellation(); guard !manager.fileExists(atPath: destination.path) else { throw CaptureError.message(L10n.text("导入目标已存在。")) }
                try manager.moveItem(at: stage, to: destination)
            }
            try await withTaskCancellationHandler(operation: { try await committing.value }, onCancel: { committing.cancel() })
            return Restored(kind: manifest.kind, directory: destination, video: manifest.kind == .video ? destination.appendingPathComponent(manifest.entry) : nil, steps: loaded.1)
        } catch {
            await Task.detached(priority: .utility) { try? manager.removeItem(at: stage) }.value
            throw error
        }
    }
    private static func validateTimelines(_ root: URL, manifest: PortableProjectManifest) throws {
        for asset in manifest.assets where asset.file.hasSuffix(".interactions.json") {
            let value = try JSONDecoder().decode(RecordingInteractions.self, from: read(root.appendingPathComponent(asset.file), limit: 32_000_000))
            guard value.version == 1, value.events.count <= 1_000_000, value.events.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= 1_000_000 && $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) && ($0.label?.utf8.count ?? 0) <= 1024 }) else { throw CaptureError.message(L10n.text("交互时间轴参数无效。")) }
        }
        for asset in manifest.assets where asset.file.hasSuffix(".drawing.json") {
            let value = try JSONDecoder().decode(RecordingDrawingTimeline.self, from: read(root.appendingPathComponent(asset.file), limit: 20_000_000))
            guard value.version == 1, value.frames.count <= 2000, value.frames.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.marks.count <= 200 && $0.marks.allSatisfy({ [.arrow, .rectangle, .ellipse, .pen, .step].contains($0.tool) && $0.overlayPNG == nil && $0.rgba.count == 4 && $0.rgba.allSatisfy(\.isFinite) && $0.text.utf8.count <= 64_000 && ($0.fontName?.utf8.count ?? 0) <= 128 && $0.points.count <= 10_000 && $0.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) && $0.width.isFinite && (1...30).contains($0.width) && $0.fontSize.isFinite && (8...200).contains($0.fontSize) }) }) else { throw CaptureError.message(L10n.text("绘制时间轴参数无效或含不支持的图像标记。")) }
        }
        let video = root.appendingPathComponent(manifest.entry), metadata = RecordingInteractions.load(video)
        guard metadata?.editableCursorSource == manifest.cursorSource else { throw CaptureError.message(L10n.text("光标源关联与清单不符。")) }
        if manifest.cursorSource != nil { _ = try EditableCursorSource.resolve(video, metadata: metadata) }
        if let options = try RecordingEditStore.load(video)?.studio.effects, options.camera.enabled,
           (!(options.cameraLayouts ?? []).isEmpty || options.cameraAutomation?.active == true || options.privacy?.contains(where: { $0.target == .camera }) == true), manifest.camera == nil { throw CaptureError.message(L10n.text("工程需要摄像头素材，但依赖缺失。")) }
    }
}
