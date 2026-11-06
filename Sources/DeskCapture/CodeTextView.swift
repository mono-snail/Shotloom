import AppKit

final class CodeTextView: NSTextView {
    var language: TextLanguage = .plain
    var indentation: String { language == .json || language == .xml || language == .html || language == .javascript || language == .typescript ? "  " : "    " }

    override func insertTab(_ sender: Any?) {
        if selectedRange().length == 0 { insertText(indentation, replacementRange: selectedRange()) }
        else { indentSelection(removing: false) }
    }
    override func insertBacktab(_ sender: Any?) { indentSelection(removing: true) }
    override func insertNewline(_ sender: Any?) {
        let source = string as NSString
        let selection = selectedRange()
        let line = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        var indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        if language != .plain && language != .markdown {
            if trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || (language == .python && trimmed.hasSuffix(":")) { indent += indentation }
            else if (language == .xml || language == .html), trimmed.range(of: #"<[\w:.-]+(?:\s[^<>]*)?>$"#, options: .regularExpression) != nil,
                    !trimmed.hasSuffix("/>") { indent += indentation }
        }
        insertText("\n" + indent, replacementRange: selection)
    }
    private func indentSelection(removing: Bool) {
        let source = string as NSString
        let selected = selectedRange()
        let end = selected.length > 0 ? NSMaxRange(selected) - 1 : selected.location
        let first = source.lineRange(for: NSRange(location: selected.location, length: 0))
        let last = source.lineRange(for: NSRange(location: end, length: 0))
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var lines = source.substring(with: range).components(separatedBy: "\n")
        let count = lines.last == "" ? lines.count - 1 : lines.count
        for index in 0..<count {
            if removing {
                if lines[index].hasPrefix("\t") { lines[index].removeFirst() }
                else { lines[index].removeFirst(min(indentation.count, lines[index].prefix { $0 == " " }.count)) }
            } else { lines[index] = indentation + lines[index] }
        }
        let replacement = lines.joined(separator: "\n")
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }
}

final class TextLineNumberRuler: NSRulerView {
    private weak var editor: NSTextView?
    private(set) var lineStarts: [Int] = [0]
    override var isFlipped: Bool { true }
    init(scroll: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor; ruleThickness = 52
        refreshLines()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refreshLines() {
        guard let editor else { return }
        let source = editor.string as NSString
        lineStarts = [0]
        var index = 0
        while index < source.length {
            let end = NSMaxRange(source.lineRange(for: NSRange(location: index, length: 0)))
            guard end > index else { break }
            index = end
            if index < source.length || source.substring(with: NSRange(location: index - 1, length: 1)).rangeOfCharacter(from: .newlines) != nil { lineStarts.append(index) }
        }
        ruleThickness = max(48, CGFloat(String(lineStarts.count).count * 9 + 22))
        needsDisplay = true
    }
    func lineIndex(at location: Int) -> Int {
        var lower = 0, upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= location { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let visible = editor.visibleRect
        let visibleGlyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let firstLine = lineIndex(at: characters.location)
        let currentLine = lineIndex(at: editor.selectedRange().location)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let length = (editor.string as NSString).length
        for line in firstLine..<lineStarts.count {
            let location = lineStarts[line]
            if location > NSMaxRange(characters), location < length { break }
            let fragment: NSRect
            if location == length { fragment = layout.extraLineFragmentRect }
            else { fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil) }
            let point = convert(NSPoint(x: 0, y: fragment.minY + editor.textContainerOrigin.y), from: editor)
            if point.y > bounds.maxY { break }
            let number = "\(line + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: line == currentLine ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor]
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: bounds.width - size.width - 12, y: point.y + 2), withAttributes: attributes)
        }
    }
}

extension SyntaxTokenKind {
    var color: NSColor {
        let light: NSColor, dark: NSColor
        switch self {
        case .comment: light = NSColor(red: 0.36, green: 0.43, blue: 0.40, alpha: 1); dark = NSColor(red: 0.55, green: 0.62, blue: 0.57, alpha: 1)
        case .string: light = NSColor(red: 0.56, green: 0.22, blue: 0.14, alpha: 1); dark = NSColor(red: 0.95, green: 0.66, blue: 0.48, alpha: 1)
        case .number: light = NSColor(red: 0.10, green: 0.40, blue: 0.28, alpha: 1); dark = NSColor(red: 0.55, green: 0.82, blue: 0.65, alpha: 1)
        case .keyword: light = NSColor(red: 0.53, green: 0.20, blue: 0.59, alpha: 1); dark = NSColor(red: 0.81, green: 0.59, blue: 0.90, alpha: 1)
        case .type, .attribute: light = NSColor(red: 0.40, green: 0.32, blue: 0.12, alpha: 1); dark = NSColor(red: 0.88, green: 0.77, blue: 0.46, alpha: 1)
        case .key, .tag, .heading: light = NSColor(red: 0.02, green: 0.39, blue: 0.52, alpha: 1); dark = NSColor(red: 0.43, green: 0.79, blue: 0.90, alpha: 1)
        }
        return NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

final class EditorSurfaceView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { StudioNativeColor.paper.setFill(); dirtyRect.fill() }
}
