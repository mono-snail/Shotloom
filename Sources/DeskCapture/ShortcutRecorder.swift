import AppKit
import SwiftUI

final class ShortcutCaptureField: NSTextField {
    var onBinding: ((HotKeyBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        stringValue = L10n.text("现在按下组合键…")
        return true
    }
    var savedLabel = ""
    override func resignFirstResponder() -> Bool { stringValue = savedLabel; return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        // Tab moves through the form; modified Tab can still be recorded.
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }

        if let binding = HotKeyBinding(event: event) { stringValue = binding.label; onBinding?(binding); window?.makeFirstResponder(nil) }
        else { stringValue = L10n.text("请包含 ⌘ 或 ⌃ 修饰键") }
    }
}
private struct ShortcutCapture: NSViewRepresentable {
    let label: String
    let onBinding: (HotKeyBinding) -> Void
    func makeNSView(context: Context) -> ShortcutCaptureField {
        let field = ShortcutCaptureField()
        field.isEditable = false; field.isSelectable = false; field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.focusRingType = .exterior; field.onBinding = onBinding
        return field
    }
    func updateNSView(_ field: ShortcutCaptureField, context: Context) { field.savedLabel = label; if field.window?.firstResponder !== field { field.stringValue = label }; field.onBinding = onBinding }
}

struct ShortcutRecorder: View {
    let label: String
    let onBinding: (HotKeyBinding) -> Void
    var onClear: (() -> Void)? = nil
    var canClear = false
    var body: some View {
        HStack(spacing: 8) {
            ShortcutCapture(label: label, onBinding: onBinding)
                .frame(maxWidth: .infinity).clipped()
                .accessibilityLabel(L10n.text("快捷键，点击后按组合键"))
            if let onClear {
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).opacity(canClear ? 1 : 0.55).help(L10n.text("清除热键或取消录入"))
                    .accessibilityLabel(L10n.text("清除热键"))
            }
        }
    }
}
