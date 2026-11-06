import AppKit
import Combine
import UniformTypeIdentifiers

struct WorkflowAppearance: Codable, Equatable {
    var style: BeautifyStyle = .aurora
    var layout: BeautifyLayout = .original
    var padding = 0.09
    var roundness = 0.27
    func validate() throws {
        guard padding.isFinite, (0...0.35).contains(padding), roundness.isFinite, (0...1).contains(roundness) else {
            throw CaptureError.message(L10n.text("请检查美化留白和圆角参数。"))
        }
    }
}

struct WorkflowOutput: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case preview, copyImage, saveImage, copyText, saveText
        var id: String { rawValue }
        var title: String {
            switch self { case .preview: L10n.text("仅预览"); case .copyImage: L10n.text("复制图片"); case .saveImage: L10n.text("保存图片"); case .copyText: L10n.text("复制文字"); case .saveText: L10n.text("保存文字") }
        }
    }
    enum Format: String, Codable, CaseIterable, Identifiable {
        case png, jpeg, tiff, heic, pdf
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
    }
    var kind: Kind = .copyImage
    var format: Format = .png
    var prefix = "DeskCapture"
    var directoryBookmark: Data?
    var directoryName: String?
    var writesFile: Bool { kind == .saveImage || kind == .saveText }
    func validate(hasText: Bool) throws {
        guard ![.copyText, .saveText].contains(kind) || hasText else {
            throw CaptureError.message(L10n.text("文字输出需要把“识别文字”放在最后一步。"))
        }
        guard writesFile else { return }
        guard (1...40).contains(prefix.count), !prefix.contains(where: { "/:\\".contains($0) || $0.isNewline }),
              prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              (directoryBookmark?.count ?? 0) <= 100_000, (directoryName?.count ?? 0) <= 1024 else {
            throw CaptureError.message(L10n.text("文件名前缀需为1–40字，且不能包含路径分隔符；保存目录需有效。"))
        }
    }
    func filename(now: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(formatter.string(from: now)) \(UUID().uuidString.prefix(8)).\(kind == .saveText ? "txt" : format.rawValue)"
    }
}

extension Notification.Name {
    static let workflowLibraryChanged = Notification.Name("DeskCapture.workflowLibraryChanged")
}

@MainActor final class WorkflowCatalog: ObservableObject {
    static let shared = WorkflowCatalog()
    @Published private(set) var recipes: [LocalWorkflowRecipe] = []
    @Published private(set) var error: String?
    private var generation = UUID()
    private var subscription: AnyCancellable?
    var pinned: [LocalWorkflowRecipe] { recipes.filter { $0.inCaptureToolbar == true } }
    init() {
        subscription = NotificationCenter.default.publisher(for: .workflowLibraryChanged).sink { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
    func refresh() async {
        let token = UUID(); generation = token
        do {
            let values = try await LocalWorkflowLibrary.shared.list()
            guard generation == token, !Task.isCancelled else { return }
            recipes = values; error = nil
        } catch {
            if generation == token, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// Encoding happens before commit. Unique generated names never replace a file
/// which appeared in the destination directory while the encoder was running.
enum WorkflowFileDelivery {
    static func write(_ result: LocalWorkflowResult, output: WorkflowOutput, to url: URL, replaceExisting: Bool) throws {
        try Task.checkCancellation()
        let stage = url.deletingLastPathComponent().appendingPathComponent(".deskflow-\(UUID()).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: stage) }
        if output.kind == .saveText {
            guard let text = result.text else { throw CaptureError.message(L10n.text("流程没有产生文字。")) }
            try Data(text.utf8).write(to: stage, options: .withoutOverwriting)
        } else { try CaptureImageExport.write(result.image, to: stage) }
        try Task.checkCancellation()
        if replaceExisting {
            // The save panel has already obtained any overwrite decision.
            let data = try Data(contentsOf: stage, options: .mappedIfSafe)
            try LocalWorkflowFiles.write(data, to: url)
        } else { try FileManager.default.moveItem(at: stage, to: url) }
    }

    static func saveInFolder(_ result: LocalWorkflowResult, output: WorkflowOutput) throws -> URL {
        guard let bookmark = output.directoryBookmark else { throw CaptureError.message(L10n.text("请重新选择保存目录。")) }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale else { throw CaptureError.message(L10n.text("保存目录授权已过期，请重新选择。")) }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CaptureError.message(L10n.text("保存目录不可用，请重新选择。"))
        }
        let url = folder.appendingPathComponent(output.filename())
        try write(result, output: output, to: url, replaceExisting: false)
        return url
    }
}

@MainActor final class WorkflowDelivery: ObservableObject {
    let feedback = ImageDeliveryFeedback()
    @Published private(set) var state = ImageDeliveryState()
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var panel: NSSavePanel?
    private var generation = UUID()
    init() {
        subscription = feedback.$state.sink { [weak self] in self?.state = $0 }
    }
    func cancel() { feedback.cancel() }
    func invalidate() {
        generation = UUID(); task?.cancel(); task = nil
        let old = panel; panel = nil; old?.cancel(nil)
        feedback.invalidate()
    }
    func perform(_ output: WorkflowOutput, result: LocalWorkflowResult, app: AppCoordinator,
                 expectedClipboard: Int, parent: NSWindow?) {
        invalidate()
        switch output.kind {
        case .preview: return
        case .copyImage:
            guard app.workflowClipboardRevision == expectedClipboard else { fail(L10n.text("剪贴板已有新的内容，结果保留在预览中。")); return }
            app.copy(result.image, feedback: feedback)
        case .copyText:
            let token = feedback.begin(L10n.text("正在复制文字…"), cancel: {})
            do {
                guard let text = result.text else { throw CaptureError.message(L10n.text("流程没有产生文字。")) }
                try app.copyWorkflowText(text, expectedChange: expectedClipboard)
                feedback.complete(.copied, token: token, copiedMessage: L10n.text("文字已复制"))
            } catch { feedback.complete(.failed(error.localizedDescription), token: token) }
        case .saveImage, .saveText:
            let token = generation
            let progress = feedback.begin(output.directoryBookmark == nil ? L10n.text("选择保存位置…") : L10n.text("正在保存…"), cancel: { [weak self] in
                self?.task?.cancel(); self?.panel?.cancel(nil)
            })
            if output.directoryBookmark != nil { save(result, output: output, url: nil, token: token, progress: progress); return }
            let chooser = NSSavePanel(); panel = chooser
            chooser.nameFieldStringValue = output.filename()
            chooser.allowedContentTypes = output.kind == .saveText ? [.plainText] : [Self.contentType(output.format)]
            SavePanelPresentation.begin(chooser, parent: parent) { [weak self] response in
                guard let self, self.generation == token, self.panel === chooser else { return }
                self.panel = nil
                guard response == .OK, !self.state.cancelling, let url = chooser.url else {
                    self.feedback.complete(.cancelled, token: progress); return
                }
                self.save(result, output: output, url: url, token: token, progress: progress)
            }
        }
    }
    private func fail(_ message: String) {
        let token = feedback.begin("", cancel: {})
        feedback.complete(.failed(message), token: token)
    }
    private func save(_ result: LocalWorkflowResult, output: WorkflowOutput, url: URL?, token: UUID, progress: UUID) {
        feedback.update(L10n.text("正在保存…"), token: progress)
        task = Task { @MainActor [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> URL in
                    if let url { try WorkflowFileDelivery.write(result, output: output, to: url, replaceExisting: true); return url }
                    return try WorkflowFileDelivery.saveInFolder(result, output: output)
                }
                let saved = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == token else { return }
                // A committed file stays successful if cancellation arrives after rename.
                self.feedback.complete(.saved(saved), token: progress)
            } catch {
                guard let self, self.generation == token else { return }
                self.feedback.complete(error is CancellationError ? .cancelled : .failed(error.localizedDescription), token: progress)
            }
            if self?.generation == token { self?.task = nil }
        }
    }
    private static func contentType(_ format: WorkflowOutput.Format) -> UTType {
        switch format { case .png: .png; case .jpeg: .jpeg; case .tiff: .tiff; case .heic: .heic; case .pdf: .pdf }
    }
}

@MainActor final class LocalWorkflowWindow: NSWindow, NSWindowDelegate {
    var shouldCloseRequest: (() -> Bool)?
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        delegate = self
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldCloseRequest?() ?? true }
    func windowWillClose(_ notification: Notification) { shouldCloseRequest = nil; contentView = nil }
}
