import XCTest
import AppKit
@testable import DeskCapture

final class CodeEditorTests: XCTestCase {
    func testCodeFileRoutingAndLanguageDetection() {
        let extensions: [(String, TextLanguage)] = [("XML", .xml), ("cpp", .cpp), ("h", .c), ("py", .python), ("java", .java), ("ts", .typescript), ("sh", .shell)]
        for (ext, language) in extensions {
            let url = URL(fileURLWithPath: "/tmp/code.\(ext)")
            XCTAssertEqual(ClipboardContent.kind(url), .text)
            XCTAssertEqual(TextLanguage.detect("", name: url.lastPathComponent), language)
        }
        let snippets: [(String, TextLanguage)] = [
            (#"{"a":1}"#, .json), ("<root><item /></root>", .xml), ("# Notes\ncontent", .markdown),
            ("def greet(name):\n    return name", .python), ("public class Demo {}", .java),
            ("#include <iostream>\nint main() {}", .cpp), ("#include <stdio.h>", .c),
            ("func greet() {}", .swift), ("const greeting = 'hi';", .javascript),
            ("interface User {name: string;}", .typescript), ("ordinary notes", .plain)
        ]
        for (source, expected) in snippets { XCTAssertEqual(TextLanguage.detect(source, name: "剪贴板.txt"), expected, source) }
    }

    func testEveryLanguageHasWorkingTokenRules() {
        let snippets: [(TextLanguage, String, SyntaxTokenKind)] = [
            (.json, #"{"name":"hello","n":12,"ok":true}"#, .key),
            (.xml, #"<root key="value"><!-- comment --></root>"#, .tag),
            (.html, "<html><!-- comment --></html>", .tag),
            (.c, "int main() { return 42; }", .keyword),
            (.cpp, "class Test { public: int n; };", .keyword),
            (.python, "def greet():\n    return 'hello' # comment", .keyword),
            (.java, "public class Demo { int count = 42; }", .keyword),
            (.javascript, "const n = 42; // comment", .keyword),
            (.typescript, "interface User { name: string; }", .keyword),
            (.swift, "func greet() { return 42 }", .keyword),
            (.css, "a { color: red; display: flex; }", .key),
            (.yaml, "name: test\nenabled: true", .key),
            (.shell, "export PATH='test' # comment", .keyword),
            (.markdown, "# Heading\n**bold**\n`code`", .heading)
        ]
        for (language, source, kind) in snippets {
            let tokens = TextSyntaxHighlighter.tokens(in: source, language: language)
            XCTAssertTrue(tokens.contains { $0.kind == kind }, language.title)
            for token in tokens { XCTAssertLessThanOrEqual(NSMaxRange(token.range), (source as NSString).length) }
        }
    }

    func testStringsAndCommentsShieldKeywordsWithUnicodeRanges() {
        let source = "def f():\n    value = \"你好 return 123\"\n    # return 42\n    return value"
        let tokens = TextSyntaxHighlighter.tokens(in: source, language: .python)
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual((source as NSString).substring(with: strings[0].range), "\"你好 return 123\"")
        XCTAssertEqual(tokens.filter { $0.kind == .keyword && (source as NSString).substring(with: $0.range) == "return" }.count, 1)
        let triple = "doc = \"\"\"return\nclass\"\"\"\nreturn 1"
        XCTAssertEqual(TextSyntaxHighlighter.tokens(in: triple, language: .python).filter { $0.kind == .string }.count, 1)
    }

    func testXMLFormattingPreservesContentAndIsIdempotent() throws {
        let source = #"<?xml version="1.0"?><root z="2" a="1"><item>你好 &amp; 世界</item><empty/></root>"#
        let output = try XMLTextFormatter.format(source)
        XCTAssertEqual(output, "<?xml version=\"1.0\"?>\n<root z=\"2\" a=\"1\">\n  <item>你好 &amp; 世界</item>\n  <empty/>\n</root>")
        XCTAssertEqual(try XMLTextFormatter.format(output), output)
        XCTAssertEqual(try XMLTextFormatter.format("<p>hello <b>world</b> !</p>"), "<p>hello <b>world</b> !</p>")
        XCTAssertEqual(try XMLTextFormatter.format("<a><![CDATA[x < y && z > q]]></a>"), "<a><![CDATA[x < y && z > q]]></a>")
        XCTAssertEqual(try XMLTextFormatter.format(#"<r xml:space="preserve"> <a/>  <b/> </r>"#), #"<r xml:space="preserve"> <a/>  <b/> </r>"#)
        XCTAssertThrowsError(try XMLTextFormatter.format("<a><b></a>"))
        XCTAssertThrowsError(try XMLTextFormatter.format("<a x='1' x='2'/>"))
        XCTAssertThrowsError(try XMLTextFormatter.format("hello"))
    }

    func testXMLDeclarationsCommentsAndQuotedDelimiters() throws {
        let source = #"<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE root [<!ENTITY test "content">]><root><!-- comment --><a attr="x > y &amp; z">&test;</a></root>"#
        let output = try XMLTextFormatter.format(source)
        XCTAssertTrue(output.contains(#"encoding="UTF-16""#))
        XCTAssertTrue(output.contains(#"<!DOCTYPE root [<!ENTITY test "content">]>"#))
        XCTAssertTrue(output.contains("  <!-- comment -->\n"))
        XCTAssertTrue(output.contains(#"<a attr="x > y &amp; z">&test;</a>"#))
    }

    @MainActor
    func testXMLFormattingAndIndentationCanUndo() throws {
        _ = NSApplication.shared
        let source = "<root><child/></root>"
        let editor = ClipboardEditor(text: source, name: "test.xml", report: { _ in })
        defer { editor.window.delegate = nil; editor.window.close() }
        XCTAssertEqual(editor.language, .xml)
        editor.formatText()
        XCTAssertEqual(editor.textView.string, "<root>\n  <child/>\n</root>")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, source)
        let code = CodeTextView(); code.isRichText = false; code.allowsUndo = true; code.language = .python
        code.string = "def f():"; code.setSelectedRange(NSRange(location: (code.string as NSString).length, length: 0))
        code.insertNewline(nil)
        XCTAssertEqual(code.string, "def f():\n    ")
        code.insertTab(nil)
        XCTAssertTrue(code.string.hasSuffix("        "))
        code.insertBacktab(nil)
        XCTAssertTrue(code.string.hasSuffix("    "))
    }

    @MainActor
    func testMalformedXMLRemainsUntouchedAndHasVisibleError() {
        _ = NSApplication.shared
        let editor = ClipboardEditor(text: "<root><broken></root>", name: "test.xml", report: { _ in })
        defer { editor.window.delegate = nil; editor.window.close() }
        editor.formatText()
        XCTAssertEqual(editor.textView.string, "<root><broken></root>")
        XCTAssertFalse(editor.window.isDocumentEdited)
    }
    func testXMLSaveEncodingMatchesDeclaration() throws {
        let source = #"<?xml version="1.0" encoding="UTF-16"?><root>中文</root>"#
        let data = try XMLTextFormatter.dataForSaving(source)
        XCTAssertEqual(String(data: data, encoding: .utf16), source)
        XCTAssertTrue(XMLParser(data: data).parse())
        XCTAssertThrowsError(try XMLTextFormatter.dataForSaving(#"<?xml version="1.0" encoding="unknown-charset"?><root/>"#))
        XCTAssertEqual(try XMLTextFormatter.dataForSaving("<root>中文</root>"), Data("<root>中文</root>".utf8))
    }

    @MainActor
    func testHighlightingLeavesTextSelectionAndUndoUntouched() async throws {
        _ = NSApplication.shared
        let source = #"{"name":"你好","value":42}"#
        let editor = ClipboardEditor(text: source, name: "test.json", report: { _ in })
        defer { editor.window.delegate = nil; editor.window.close() }
        editor.textView.setSelectedRange(NSRange(location: 3, length: 2))
        try await Task.sleep(nanoseconds: 350_000_000)
        let layout = try XCTUnwrap(editor.textView.layoutManager)
        XCTAssertNotNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 1, effectiveRange: nil))
        XCTAssertEqual(editor.textView.string, source)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 3, length: 2))
        XCTAssertFalse(editor.window.isDocumentEdited)
        XCTAssertFalse(editor.textView.undoManager?.canUndo ?? false)
        editor.formatText()
        try await Task.sleep(nanoseconds: 300_000_000)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, source)
    }

    @MainActor
    func testAutomaticLanguageSurvivesIncompleteJSONAndManualOverride() throws {
        _ = NSApplication.shared
        let editor = ClipboardEditor(text: #"{"a":1}"#, name: "剪贴板.txt", report: { _ in })
        defer { editor.window.delegate = nil; editor.window.close() }
        XCTAssertEqual(editor.language, .json)
        editor.textView.insertText("{\"a\":", replacementRange: NSRange(location: 0, length: (editor.textView.string as NSString).length))
        XCTAssertEqual(editor.language, .json)
        func picker(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.compactMap { picker(in: $0) }.first
        }
        let popup = try XCTUnwrap(picker(in: XCTUnwrap(editor.window.contentView)))
        popup.selectItem(withTitle: "Python")
        NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
        XCTAssertEqual(editor.language, .python)
        XCTAssertEqual(editor.textView.string, "{\"a\":")
    }

}
