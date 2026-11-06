import AppKit

final class TextAnnotationEditor: NSObject, NSTextFieldDelegate {
    private let field = NSTextField()
    private weak var parent: NSView?
    private var completion: ((String) -> Void)?
    init(in parent: NSView, at point: CGPoint, fontSize: CGFloat, color: NSColor, completion: @escaping (String) -> Void) {
        self.parent = parent; self.completion = completion
        super.init()
        let width = min(280, max(120, parent.bounds.width - 24))
        field.frame = CGRect(x: min(max(12, point.x), parent.bounds.width - width - 12),
                             y: min(max(12, point.y), parent.bounds.height - 42), width: width, height: 34)
        field.placeholderString = L10n.text("输入文字，Enter 完成")
        field.font = .systemFont(ofSize: max(13, fontSize), weight: .medium)
        field.textColor = color; field.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.09, blue: 0.15, alpha: 0.96)
        field.drawsBackground = true; field.isBezeled = false; field.isEditable = true
        field.focusRingType = .none; field.delegate = self
        field.wantsLayer = true; field.layer?.cornerRadius = 6
        parent.addSubview(field); parent.window?.makeFirstResponder(field)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finish(field.stringValue); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finish(""); return true }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { finish(field.stringValue) }
    func commit() { finish(field.stringValue) }
    private func finish(_ text: String) {
        guard let completion else { return }; self.completion = nil
        field.removeFromSuperview(); parent?.window?.makeFirstResponder(parent)
        completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
