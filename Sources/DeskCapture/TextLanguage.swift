import Foundation

enum TextLanguage: String, CaseIterable, Sendable {
    case plain, markdown, json, xml, c, cpp, python, java, javascript, typescript, swift, html, css, yaml, shell
    var title: String {
        switch self {
        case .plain: return L10n.text("纯文本")
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .xml: return "XML"
        case .c: return "C"
        case .cpp: return "C++"
        case .python: return "Python"
        case .java: return "Java"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .swift: return "Swift"
        case .html: return "HTML"
        case .css: return "CSS"
        case .yaml: return "YAML"
        case .shell: return "Shell"
        }
    }
    var fileExtension: String {
        switch self {
        case .plain: return "txt"
        case .markdown: return "md"
        case .cpp: return "cpp"
        case .python: return "py"
        case .javascript: return "js"
        case .typescript: return "ts"
        case .shell: return "sh"
        default: return rawValue
        }
    }
    var supportsFormatting: Bool { self == .json || self == .xml }

    static func fromExtension(_ ext: String) -> TextLanguage? {
        switch ext.lowercased() {
        case "txt", "log", "csv", "tsv": return .plain
        case "md", "markdown": return .markdown
        case "json", "jsonl": return .json
        case "xml", "xsd", "xsl", "xslt", "svg", "plist": return .xml
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return .cpp
        case "py", "pyw": return .python
        case "java": return .java
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx": return .typescript
        case "swift": return .swift
        case "html", "htm": return .html
        case "css", "scss": return .css
        case "yaml", "yml": return .yaml
        case "sh", "bash", "zsh": return .shell
        default: return nil
        }
    }

    /// Extensions for named code files are authoritative; pasted text uses conservative hints.
    static func detect(_ source: String, name: String) -> TextLanguage {
        if let language = fromExtension((name as NSString).pathExtension), language != .plain { return language }
        let sample = String(source.prefix(32_768)).trimmingCharacters(in: .whitespacesAndNewlines)
        if (sample.hasPrefix("{") || sample.hasPrefix("[")),
           (try? JSONSerialization.jsonObject(with: Data(source.utf8))) != nil { return .json }
        if sample.range(of: #"(?i)^<!doctype\s+html|^<html\b"#, options: .regularExpression) != nil { return .html }
        if sample.hasPrefix("<?xml") || sample.range(of: #"^<[A-Za-z_][\w:.-]*(?:\s|>|/)"#, options: .regularExpression) != nil { return .xml }
        let hints: [(TextLanguage, String)] = [
            (.python, #"(?m)^\s*(?:def\s+\w+\s*\(|from\s+\w+\s+import\b|import\s+(?:os|sys|numpy|pandas)\b)|^#!.*python"#),
            (.java, #"\b(?:public\s+(?:class|interface)|System\.out\.|import\s+java\.)"#),
            (.cpp, #"\bstd::|#\s*include\s*<(?:iostream|vector|string)>|\b(?:template\s*<|nullptr\b)"#),
            (.c, #"#\s*include\b|\bint\s+main\s*\(|\bprintf\s*\("#),
            (.swift, #"\b(?:func\s+\w+\s*\(|import\s+(?:Foundation|AppKit|SwiftUI)|guard\s+let)"#),
            (.typescript, #"\b(?:interface\s+\w+|type\s+\w+\s*=)|:\s*(?:string|number|boolean)\b"#),
            (.javascript, #"\b(?:function\s+\w*\s*\(|(?:const|let)\s+\w+\s*=|console\.log\s*\()"#),
            (.shell, #"^#!.*(?:sh|bash|zsh)|(?m)^\s*(?:export\s+\w+=|if\s+\[)"#),
            (.markdown, #"(?m)^#{1,6}\s+\S|^```\w*\s*$|\[[^\]]+\]\(https?://"#),
            (.yaml, #"(?m)^\w[\w.-]*:\s+\S[\s\S]*\n\w[\w.-]*:"#)
        ]
        for (language, pattern) in hints where sample.range(of: pattern, options: .regularExpression) != nil { return language }
        return .plain
    }
}

enum SyntaxTokenKind: String, Sendable { case comment, string, number, keyword, type, key, tag, attribute, heading }
struct SyntaxToken: Sendable {
    let range: NSRange
    let kind: SyntaxTokenKind
}

enum TextSyntaxHighlighter {
    private static let expressions: [TextLanguage: NSRegularExpression] = {
        Dictionary(uniqueKeysWithValues: TextLanguage.allCases.compactMap { language in
            let rules = rules(for: language)
            guard !rules.isEmpty, let regex = try? NSRegularExpression(pattern: rules.map { "(?<\($0.0.rawValue)>\($0.1))" }.joined(separator: "|")) else { return nil }
            return (language, regex)
        })
    }()
    static func tokens(in source: String, language: TextLanguage) -> [SyntaxToken] {
        guard let regex = expressions[language] else { return [] }
        var tokens: [SyntaxToken] = []
        let kinds = rules(for: language).map(\.0)
        regex.enumerateMatches(in: source, range: NSRange(location: 0, length: (source as NSString).length)) { match, _, _ in
            guard let match else { return }
            for kind in kinds where match.range(withName: kind.rawValue).location != NSNotFound {
                tokens.append(SyntaxToken(range: match.range, kind: kind)); break
            }
        }
        return tokens
    }
    private static func words(_ value: String) -> String { "\\b(?:" + value.split(separator: " ").joined(separator: "|") + ")\\b" }
    private static func rules(for language: TextLanguage) -> [(SyntaxTokenKind, String)] {
        let quoted = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#
        let number = #"\b(?:0[xX][\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[fFuUlL]*\b"#
        if language == .plain { return [] }
        if language == .json {
            return [(.key, #""(?:\\.|[^"\\])*"(?=\s*:)"#), (.string, #""(?:\\.|[^"\\])*""#), (.number, number), (.keyword, words("true false null"))]
        }
        if language == .xml || language == .html {
            return [(.comment, #"<!--[\s\S]*?(?:-->|$)|<\?[\s\S]*?(?:\?>|$)|<!DOCTYPE[\s\S]*?>"#),
                    (.string, #"<!\[CDATA\[[\s\S]*?(?:\]\]>|$)|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#),
                    (.tag, #"</?[A-Za-z_][\w:.-]*|/?>"#), (.attribute, #"\b[A-Za-z_][\w:.-]*(?=\s*=)"#)]
        }
        if language == .markdown {
            return [(.string, #"(?m)^\s*```[\s\S]*?(?:^\s*```\s*$|\z)|`[^`\n]+`"#), (.heading, #"(?m)^#{1,6}\s+.*$"#),
                    (.key, #"\[[^\]\n]*\]\([^\)\n]*\)"#), (.keyword, #"\*\*[^\n]*?\*\*|(?m)^\s*(?:[-*+] |\d+\. |>).*"#)]
        }
        var rules: [(SyntaxTokenKind, String)] = []
        if language == .python {
            rules += [(.string, #"(?i:(?:r|u|b|f|br|rb|fr|rf)?)(?:\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')"#), (.comment, #"#[^\n]*"#)]
        } else if language == .shell || language == .yaml {
            rules += [(.string, quoted), (.comment, #"#[^\n]*"#)]
        } else {
            rules += [(.comment, #"//[^\n]*|/\*[\s\S]*?(?:\*/|\z)"#), (.string, #"`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)]
        }
        let keywords: String
        switch language {
        case .c, .cpp: keywords = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while class namespace using template typename public private protected virtual override final new delete try catch throw constexpr nullptr true false this operator friend"
        case .python: keywords = "False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self"
        case .java: keywords = "abstract assert break case catch class const continue default do else enum extends final finally for if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while true false null var record sealed"
        case .swift: keywords = "actor associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate for func guard if import in init inout internal is let nonisolated open operator private protocol public repeat rethrows return self some static struct subscript super switch throw throws try typealias var weak where while true false nil"
        case .javascript, .typescript: keywords = "async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield true false null undefined interface type implements public private protected readonly enum namespace as"
        case .css: keywords = "important inherit initial unset none auto block flex grid absolute relative solid"
        case .yaml: keywords = "true false null yes no"
        case .shell: keywords = "if then else elif fi for while do done case esac function in export local readonly return exit echo cd"
        default: keywords = ""
        }
        if !keywords.isEmpty { rules += [(.keyword, words(keywords))] }
        rules += [(.number, number)]
        if language == .yaml || language == .css { rules += [(.key, #"[\w.-]+(?=\s*:)"#)] }
        else { rules += [(.type, words("int float double char bool boolean void long short signed unsigned String Integer List Map Set Array Dictionary Optional Int Float Double Bool Character Any Object str list dict tuple set bytes"))] }
        return rules
    }
}
