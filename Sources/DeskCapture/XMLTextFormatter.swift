import Foundation
import CoreFoundation

/// Keeps original tag spelling, attribute order, entities and mixed-content text.
enum XMLTextFormatter {
    private enum Kind { case open, close, empty, text, special, cdata }
    private struct Token { let text: String; let kind: Kind }

    static func format(_ source: String) throws -> String {
        guard source.utf8.count <= 10_000_000 else { throw CaptureError.message(L10n.text("XML 超过 10 MB。")) }
        // Input is already decoded text; its original encoding declaration is
        // retained in the output but must describe UTF-8 for parser validation.
        let validation = source.replacingOccurrences(of: #"(?i)(<\?xml\b[^?]*\bencoding\s*=\s*)["'][^"']*["']"#,
                                                      with: "$1\"UTF-8\"", options: .regularExpression)
        let parser = XMLParser(data: Data(validation.utf8))
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw NSError(domain: "DeskCapture.XML", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L10n.text("第 \(parser.lineNumber) 行，第 \(parser.columnNumber) 列：\(parser.parserError?.localizedDescription ?? L10n.text("XML 结构无效。"))")])
        }
        let tokens = tokenize(source)
        guard tokens.count <= 200_000 else { throw CaptureError.message(L10n.text("XML 节点数量超过格式化上限。")) }
        var stack: [Int] = []
        var closing: [Int: Int] = [:]
        var preserve = Set<Int>()
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .open:
                stack.append(index)
                guard stack.count <= 128 else { throw CaptureError.message(L10n.text("XML 嵌套超过 128 层，无法安全格式化。")) }
                if token.text.range(of: #"\bxml:space\s*=\s*(?:"preserve"|'preserve')"#, options: .regularExpression) != nil { preserve.insert(index) }
            case .close:
                if let opening = stack.popLast() { closing[opening] = index }
            case .text:
                if !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let parent = stack.last { preserve.insert(parent) }
            case .cdata:
                if let parent = stack.last { preserve.insert(parent) }
            default: break
            }
        }
        var output: [String] = []
        var bytes = 0
        func append(_ line: String) throws {
            bytes += line.utf8.count + 1
            guard bytes <= 20_000_000 else { throw CaptureError.message(L10n.text("格式化输出超过 20 MB。")) }
            output.append(line)
        }
        var depth = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.kind == .text { index += 1; continue }
            if token.kind == .close { depth -= 1 }
            let indent = String(repeating: "  ", count: max(0, depth))
            if token.kind == .open, preserve.contains(index), let end = closing[index] {
                try append(indent + tokens[index...end].map(\.text).joined())
                index = end + 1
                continue
            }
            try append(indent + token.text)
            if token.kind == .open { depth += 1 }
            index += 1
        }
        return output.joined(separator: "\n")
    }

    static func encodingName(in source: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"(?i)^\s*<\?xml\b[^?]*\bencoding\s*=\s*["']([^"']+)["']"#)
        let ns = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: min(ns.length, 1024))) else { return "UTF-8" }
        return ns.substring(with: match.range(at: 1))
    }
    static func dataForSaving(_ source: String) throws -> Data {
        let name = encodingName(in: source)
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId,
              let data = source.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))) else {
            throw NSError(domain: "DeskCapture.XML", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("无法使用 XML 声明的 \(name) 编码保存。请将声明改为 UTF-8 后重试。")])
        }
        return data
    }

    private static func tokenize(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let start = cursor
            if source[cursor] != "<" {
                while cursor < source.endIndex, source[cursor] != "<" { source.formIndex(after: &cursor) }
                tokens.append(Token(text: String(source[start..<cursor]), kind: .text)); continue
            }
            let suffix = source[cursor...]
            var kind: Kind = .special
            let terminator: String?
            if suffix.hasPrefix("<!--") { terminator = "-->" }
            else if suffix.hasPrefix("<![CDATA[") { terminator = "]]>"; kind = .cdata }
            else if suffix.hasPrefix("<?") { terminator = "?>" }
            else { terminator = nil }
            if let terminator, let end = source.range(of: terminator, range: cursor..<source.endIndex) {
                cursor = end.upperBound
            } else {
                var quote: Character?
                var brackets = 0
                source.formIndex(after: &cursor)
                while cursor < source.endIndex {
                    let character = source[cursor]
                    source.formIndex(after: &cursor)
                    if let active = quote { if character == active { quote = nil }; continue }
                    if character == "\"" || character == "'" { quote = character }
                    else if character == "[" { brackets += 1 }
                    else if character == "]" { brackets -= 1 }
                    else if character == ">", brackets == 0 { break }
                }
                let text = source[start..<cursor]
                if text.hasPrefix("</") { kind = .close }
                else if !text.hasPrefix("<!") { kind = text.hasSuffix("/>") ? .empty : .open }
            }
            tokens.append(Token(text: String(source[start..<cursor]), kind: kind))
        }
        return tokens
    }
}
