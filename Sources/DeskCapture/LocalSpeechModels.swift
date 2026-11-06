import Foundation
import CryptoKit

private final class SpeechDownloadBudget: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
}

enum LocalSpeechTier: String, Codable, CaseIterable, Identifiable {
    case tiny, base, small
    var id: String { rawValue }
    var title: String { switch self { case .tiny: L10n.text("Tiny · 78 MB"); case .base: L10n.text("Base · 148 MB"); case .small: L10n.text("Small · 488 MB") } }
    var bytes: Int64 { switch self { case .tiny: 77_691_713; case .base: 147_951_465; case .small: 487_601_967 } }
    var sha256: String { switch self {
        case .tiny: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"
        case .base: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .small: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
    } }
    var downloadURL: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue).bin")! }
}

actor LocalSpeechModels {
    static let shared = LocalSpeechModels()
    let root: URL
    private var active: LocalSpeechTier?
    private var downloading = Set<LocalSpeechTier>()
    init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("speech-models") }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskCapture/SpeechModels")
    }
    func url(_ tier: LocalSpeechTier) -> URL { root.appendingPathComponent("ggml-\(tier.rawValue).bin") }
    func installed() -> Set<LocalSpeechTier> {
        Set(LocalSpeechTier.allCases.filter { tier in
            let values = try? url(tier).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && values?.fileSize == Int(tier.bytes)
        })
    }
    static func verify(_ file: URL, tier: LocalSpeechTier) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == Int(tier.bytes) else { throw CaptureError.message(L10n.text("模型格式或大小与所选档位不符。")) }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == tier.sha256 else { throw CaptureError.message(L10n.text("模型SHA-256校验失败，未安装。")) }
    }
    func importFile(_ file: URL, tier: LocalSpeechTier) throws {
        guard active != tier else { throw CaptureError.message(L10n.text("该模型正在转写，请稍后管理。")) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".import-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: stage) }
        try Self.verify(file, tier: tier)
        try FileManager.default.copyItem(at: file, to: stage)
        try Self.verify(stage, tier: tier); try Task.checkCancellation()
        let destination = url(tier)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: destination) }
    }
    func download(_ tier: LocalSpeechTier) async throws {
        guard !downloading.contains(tier), active != tier else { throw CaptureError.message(L10n.text("该模型正在使用或下载。")) }
        downloading.insert(tier); defer { downloading.remove(tier) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration, delegate: SpeechDownloadBudget(limit: tier.bytes), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: tier.downloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CaptureError.message(L10n.text("模型下载未成功，现有模型保持不变。")) }
        try Task.checkCancellation(); try importFile(temporary, tier: tier)
    }
    func remove(_ tier: LocalSpeechTier) throws {
        guard active != tier, !downloading.contains(tier) else { throw CaptureError.message(L10n.text("该模型正在使用或下载。")) }
        if FileManager.default.fileExists(atPath: url(tier).path) { try FileManager.default.removeItem(at: url(tier)) }
    }
    func acquire(_ tier: LocalSpeechTier) throws -> URL {
        guard active == nil else { throw CaptureError.message(L10n.text("已有本地转写任务，请完成或取消后再开始。")) }
        try Self.verify(url(tier), tier: tier)
        active = tier; return url(tier)
    }
    func release(_ tier: LocalSpeechTier) { if active == tier { active = nil } }
}
