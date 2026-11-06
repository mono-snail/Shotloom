import AppKit
import UniformTypeIdentifiers

/// Value snapshots retain immutable CGImages/NSColors and copied annotation
/// arrays. They never read mutable editor state on the worker thread.
struct CanvasRenderSnapshot: @unchecked Sendable {
    let source: CGImage
    let marks: [Annotation]
    let preset: TutorialPreset?
    func png() throws -> Data {
        try Task.checkCancellation()
        let document = AnnotationDocument(image: source); document.marks = marks; document.tutorialPreset = preset
        guard let image = document.render(), let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CaptureError.message(L10n.text("拖出图片合成失败。")) }
        try Task.checkCancellation(); return bytes
    }
}

/// NSItemProvider can invoke its loader off-main; this actor owns all references
/// back to the editor and coalesces repeated requests for the same PNG.
@MainActor private final class CanvasDragTransfer {
    weak var document: AnnotationDocument?
    let snapshot: CanvasRenderSnapshot
    let revision: Int
    let owner: NSWindow?
    private var worker: Task<Data, Error>?
    init(document: AnnotationDocument) {
        self.document = document; snapshot = .init(source: document.original, marks: document.marks, preset: document.tutorialPreset)
        revision = document.renderRevision; owner = document.presentationWindow
    }
    func data() async throws -> Data {
        guard let document, !document.preparingPixels, revision == document.renderRevision, owner?.isVisible != false else { throw CancellationError() }
        if worker == nil { let snapshot = snapshot; worker = Task.detached(priority: .userInitiated) { try snapshot.png() } }
        let bytes = try await worker!.value
        try Task.checkCancellation()
        guard revision == document.renderRevision, !document.preparingPixels, owner?.isVisible != false else { throw CancellationError() }
        return bytes
    }
}

extension AnnotationDocument {
    @MainActor func outputDragProvider() -> NSItemProvider {
        guard !preparingPixels, !replacingOCR, !arrangingMarks else { reportPixelPreparationError(L10n.text("图像处理尚未完成，请完成或取消后再拖出。")); return NSItemProvider() }
        commitPendingText?()
        let transfer = CanvasDragTransfer(document: self), provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task { @MainActor in
                do { let bytes = try await transfer.data(); progress.completedUnitCount = 1; completion(bytes, nil) }
                catch { completion(nil, error) }
            }
            progress.cancellationHandler = { task.cancel() }
            if progress.isCancelled { task.cancel() }
            return progress
        }
        return provider
    }
}
