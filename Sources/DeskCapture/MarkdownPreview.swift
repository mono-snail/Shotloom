import AppKit

/// Native, read-only Markdown rendering; inline markup is parsed by Foundation.
enum MarkdownPreview {
    static func render(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var fence: Character?
        var fenceLength = 0
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first
            let count = trimmed.prefix { $0 == marker }.count
            if let active = fence {
                if marker == active, count >= fenceLength, trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                } else {
                    result.append(NSAttributedString(string: line + "\n", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor
                    ]))
                }
                continue
            }
            if (marker == "`" || marker == "~"), count >= 3 {
                fence = marker; fenceLength = count
                continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8; paragraph.lineSpacing = 3
            var text = line
            var font = NSFont.systemFont(ofSize: 14)
            var color = NSColor.labelColor
            let heading = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(heading), trimmed.dropFirst(heading).first == " " {
                text = String(trimmed.dropFirst(heading + 1))
                font = .systemFont(ofSize: CGFloat([28, 24, 20, 18, 16, 15][heading - 1]), weight: .bold)
                paragraph.paragraphSpacingBefore = 10
            } else if trimmed.hasPrefix(">") {
                text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                paragraph.headIndent = 14; paragraph.firstLineHeadIndent = 14
                color = .secondaryLabelColor
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                text = "• " + trimmed.dropFirst(2)
                paragraph.headIndent = 18
            } else if trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
                text = trimmed; paragraph.headIndent = 24
            } else if trimmed.count >= 3, Set(trimmed.filter { !$0.isWhitespace }).count == 1,
                      ["-", "*", "_"].contains(trimmed.first) {
                text = "────────────────────────"; color = .separatorColor
            }
            result.append(inline(text, font: font, color: color, paragraph: paragraph))
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        }
        return result
    }

    private static func inline(_ text: String, font: NSFont, color: NSColor, paragraph: NSParagraphStyle) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let output = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                attributes[.link] = link; attributes[.foregroundColor] = NSColor.linkColor
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
}

enum JSONTextFormatter {
    static func format(_ source: String) throws -> String {
        // Validate with Foundation, then change only whitespace. Re-encoding the
        // decoded object could round large numbers or discard duplicate keys.
        _ = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
        let characters = Array(source)
        var output = ""
        var depth = 0
        var inString = false
        var escaped = false
        var previous: Character?
        func newLine() { output += "\n" + String(repeating: "  ", count: depth) }
        for (index, character) in characters.enumerated() {
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                previous = character
                continue
            }
            guard !character.isWhitespace else { continue }
            switch character {
            case "\"":
                inString = true; output.append(character)
            case "{", "[":
                output.append(character); depth += 1
                let next = characters[(index + 1)...].first { !$0.isWhitespace }
                if next != "}" && next != "]" { newLine() }
            case "}", "]":
                depth -= 1
                if previous != "{" && previous != "[" { newLine() }
                output.append(character)
            case ",":
                output.append(character); newLine()
            case ":":
                output += ": "
            default:
                output.append(character)
            }
            previous = character
        }
        return output
    }
}
