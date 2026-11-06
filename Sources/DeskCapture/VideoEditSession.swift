import AppKit
import SwiftUI

/// Value snapshots share array storage until edited; no encoding on the UI thread.
struct VideoEditState: Equatable {
    var effects: RecordingEffectsOptions
    var captions: [CaptionSegment]
    var lenses: [RecordingLens]
    var start: Double
    var end: Double
}

@MainActor
final class VideoEditSession: ObservableObject {
    let undoManager = UndoManager()
    @Published private(set) var revision = 0
    private var current: VideoEditState?
    private var saved: VideoEditState?
    weak var window: NSWindow?
    var apply: ((VideoEditState) -> Void)?
    var saveAndClose: (() -> Void)?
    var capture: (() -> VideoEditState)?
    var didClose: (() -> Void)?
    var busy = false
    private var askingToClose = false
    var dirty: Bool { current != saved }

    init() { undoManager.levelsOfUndo = 100 }
    func begin(_ state: VideoEditState) {
        current = state; saved = state; undoManager.removeAllActions(); refresh()
    }
    func record(_ state: VideoEditState) {
        guard let previous = current, previous != state else { return }
        undoManager.registerUndo(withTarget: self) { target in target.restore(previous) }
        undoManager.setActionName(L10n.text("视频编辑"))
        current = state; refresh()
    }
    private func restore(_ state: VideoEditState) {
        guard let previous = current else { return }
        undoManager.registerUndo(withTarget: self) { target in target.restore(previous) }
        current = state; apply?(state); refresh()
    }
    func markSaved(_ state: VideoEditState) { saved = state; refresh() }
    func refresh() {
        revision += 1
        window?.isDocumentEdited = dirty
    }
    func shouldClose() -> Bool {
        if let state = capture?() { record(state) }
        guard !busy else {
            guard let window, !askingToClose else { return false }
            askingToClose = true
            let alert = NSAlert()
            alert.messageText = L10n.text("视频正在处理")
            alert.informativeText = L10n.text("请等待当前操作完成，或先取消处理再关闭。")
            alert.addButton(withTitle: L10n.text("继续编辑"))
            alert.beginSheetModal(for: window) { [weak self] _ in self?.askingToClose = false }
            return false
        }
        guard dirty, let window else { return true }
        guard !askingToClose else { return false }
        askingToClose = true
        let alert = NSAlert()
        alert.messageText = L10n.text("保存对视频的修改？")
        alert.informativeText = L10n.text("保存编辑后，下次可继续调整。原始视频不会被覆盖。")
        alert.addButton(withTitle: L10n.text("保存"))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("不保存"))
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self else { return }
            askingToClose = false
            if response == .alertFirstButtonReturn { saveAndClose?() }
            else if response == .alertThirdButtonReturn { window?.close() }
        }
        return false
    }
    func detach() {
        window?.isDocumentEdited = false
        window = nil; apply = nil; saveAndClose = nil; capture = nil; didClose = nil
        undoManager.removeAllActions()
    }
}

/// Resolve the actual hosting window, including the isolated UI gallery.
struct VideoEditWindowBinding: NSViewRepresentable {
    let session: VideoEditSession
    func makeNSView(context: Context) -> BindingView { BindingView(session: session) }
    func updateNSView(_ view: BindingView, context: Context) { view.bind() }
    final class BindingView: NSView {
        let session: VideoEditSession
        init(session: VideoEditSession) { self.session = session; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); bind() }
        func bind() {
            guard let window, session.window !== window else { return }
            session.window = window
            (window as? VideoResultPanel)?.editSession = session
            // Binding happens inside SwiftUI's representable update. The edit
            // state is unchanged; only synchronize the AppKit document marker.
            window.isDocumentEdited = session.dirty
        }
    }
}
