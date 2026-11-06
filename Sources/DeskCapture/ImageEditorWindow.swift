import AppKit

/// Closing an image editor must distinguish a flattened export from editable work.
@MainActor final class ImageEditorWindow: NSWindow, NSWindowDelegate {
    private weak var document: AnnotationDocument?
    private weak var coordinator: AppCoordinator?
    private var preserved: CaptureProjectSnapshot?
    private var prompting = false
    private(set) var preserving = false
    var beautifyCurrentImage: (() -> Void)?

    func requestBeautification() {
        guard isVisible, !isMiniaturized, attachedSheet == nil, !prompting, !preserving else { return }
        beautifyCurrentImage?()
    }

    init(document: AnnotationDocument, coordinator: AppCoordinator) {
        self.document = document; self.coordinator = coordinator
        preserved = CaptureProjectSnapshot(document)
        super.init(contentRect: CGRect(x: 0, y: 0, width: 930, height: 660),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        delegate = self
    }
    var hasUnpreservedEdits: Bool {
        guard let document else { return false }
        makeFirstResponder(nil); document.commitPendingText?()
        return preserved?.matches(document) != true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !preserving, !(document.map { coordinator?.isSavingImageHistory($0) == true } ?? false) else {
            coordinator?.flash(L10n.text("正在存入可编辑历史副本，请稍候。"))
            return false
        }
        guard !prompting else { return false }
        guard hasUnpreservedEdits else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text("保留可编辑的图片修改？")
        alert.informativeText = L10n.text("存入历史副本可继续修改标注。已导出的图片文件不会受影响。")
        alert.addButton(withTitle: L10n.text("存入历史副本"))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("不保留"))
        prompting = true
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            prompting = false
            if response == .alertFirstButtonReturn { preserveAndClose() }
            else if response == .alertThirdButtonReturn { close() }
        }
        return false
    }
    func markPreserved(_ snapshot: CaptureProjectSnapshot) {
        guard document != nil else { return }
        preserved = snapshot
    }

    private func preserveAndClose() {
        guard let document, let coordinator, !preserving else { return }
        // renderForDelivery rejects edits/closure during rendering. Capture the
        // exact accepted project before the history task gets scheduled.
        preserving = true
        document.renderForDelivery({ [weak self, weak document, weak coordinator] image in
            guard let self, let document, let coordinator, isVisible else { return }
            let snapshot = CaptureProjectSnapshot(document)
            preserving = true
            coordinator.flash(L10n.text("正在存入可编辑历史副本…"))
            coordinator.saveEdited(image, document: document) { [weak self, weak document] result in
                guard let self else { return }
                preserving = false
                guard self.document != nil else { return }
                switch result {
                case .success:
                    preserved = snapshot
                    if let document, snapshot.matches(document) { close() }
                case .failure(let error):
                    document?.reportPixelPreparationError(L10n.text("历史副本未保存：\(error.localizedDescription)"))
                }
            }
        }, finished: { [weak self, weak document, weak coordinator] in
            guard let self else { return }
            // A rejected/cancelled/stale render has no history completion to
            // release the close guard. A committed history task releases it itself.
            if document.map({ coordinator?.isSavingImageHistory($0) == true }) != true { preserving = false }
        })
    }
    func windowWillClose(_ notification: Notification) {
        beautifyCurrentImage = nil
        document?.cancelPixelPreparation()
        document?.cancelOCRReplacement()
        document?.cancelArrangement()
        contentView = nil
        preserved = nil; document = nil; coordinator = nil
    }
}
