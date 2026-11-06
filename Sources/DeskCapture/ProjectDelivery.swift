import Foundation
import AVFoundation

enum ProjectDelivery {
    static func video(_ input: URL, snapshot: RecordingEditSnapshot, expected: String, to output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-delivery-\(UUID())")
        do {
            let dependencies = try await Task.detached(priority: .utility) { try ProjectDependencySnapshot.video(input, snapshot: snapshot) }.value
            try await Task.detached(priority: .utility) {
                guard !FileManager.default.fileExists(atPath: output.path), try RecordingEditStore.fingerprint(input) == expected else { throw CaptureError.message(L10n.text("目标已存在或磁盘工程已改变，未导出交付包。")) }
                try snapshot.validate(); try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            }.value
            var options = snapshot.studio.effects ?? .init(); options.captions = snapshot.captions; options.lenses = snapshot.studio.lenses
            let start = snapshot.studio.trimStart ?? 0, end = snapshot.studio.trimEnd
            try await RecordingEffectsExporter.export(input, to: stage.appendingPathComponent("Video.mp4"), options: options, start: start, end: end, progress: { progress($0 * 0.8) })
            let duration = try await AVURLAsset(url: input).load(.duration).seconds
            let worker = Task.detached(priority: .utility) {
                let plan = try VideoEditPlan(duration: duration, start: start, end: end ?? duration, captions: snapshot.captions, sections: options.edit?.sections ?? [])
                if !snapshot.captions.isEmpty { try VideoTranscript.srt(plan.mappedCaptions(snapshot.captions)).write(to: stage.appendingPathComponent("Captions.srt"), atomically: true, encoding: .utf8) }
                try dependencies.verify()
                try PortableProject.exportVideo(input, snapshot: snapshot, expected: expected, to: stage.appendingPathComponent("Editable.deskvideo"))
                try "Editable.deskvideo包含原片和编辑设置。对外分享前请单独复核Video.mp4与Captions.srt；项目包不能当作已脱敏视频。\n".write(to: stage.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
                try Task.checkCancellation(); guard !FileManager.default.fileExists(atPath: output.path) else { throw CaptureError.message(L10n.text("目标目录已存在，未覆盖。")) }
                try dependencies.verify()
                try FileManager.default.moveItem(at: stage, to: output)
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }); progress(1)
        } catch {
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stage) }.value; throw error
        }
    }
    static func tutorial(_ steps: [TutorialStep], directory: URL, to output: URL) throws {
        let stage = output.deletingLastPathComponent().appendingPathComponent(".DeskCapture-tutorial-delivery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CaptureError.message(L10n.text("交付目录已存在，未覆盖。")) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try TutorialExporter.export(steps, directory: directory, to: stage.appendingPathComponent("Tutorial.pdf"))
        try TutorialExporter.export(steps, directory: directory, to: stage.appendingPathComponent("Tutorial.html"))
        try PortableProject.exportTutorial(steps, directory: directory, to: stage.appendingPathComponent("Editable.desktutorial"))
        try Task.checkCancellation(); try FileManager.default.moveItem(at: stage, to: output)
    }
}
