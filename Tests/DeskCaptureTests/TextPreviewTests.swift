import XCTest
import AppKit
@testable import DeskCapture

final class TextPreviewTests: XCTestCase {
    func testJSONFormattingPreservesValuesAndSupportsFragments() throws {
        let source = #"{"items":[1,true,null],"中文":"内容","url":"https://example.com/a"}"#
        let formatted = try JSONTextFormatter.format(source)
        XCTAssertTrue(formatted.contains("\n"))
        XCTAssertTrue(formatted.contains("https://example.com/a"))
        let original = try JSONSerialization.jsonObject(with: Data(source.utf8)) as! NSDictionary
        let output = try JSONSerialization.jsonObject(with: Data(formatted.utf8)) as! NSDictionary
        XCTAssertEqual(original, output)
        XCTAssertEqual(try JSONTextFormatter.format("null"), "null")
        XCTAssertEqual(try JSONTextFormatter.format("42"), "42")
        let precise = #"{"n":900719925474099312345,"decimal":1.234567890123456789,"n":2}"#
        let prettyPrecise = try JSONTextFormatter.format(precise)
        XCTAssertTrue(prettyPrecise.contains("900719925474099312345"))
        XCTAssertTrue(prettyPrecise.contains("1.234567890123456789"))
        XCTAssertEqual(prettyPrecise.components(separatedBy: "\"n\"").count, 3)
        XCTAssertEqual(try JSONTextFormatter.format(#"{"a":[],"b":{},"s":"escaped \" quote"}"#).contains(#"escaped \" quote"#), true)
        XCTAssertThrowsError(try JSONTextFormatter.format(#"{"a":}"#))
    }

    @MainActor
    func testMarkdownRendersBlocksAndInlineFormatting() {
        let output = MarkdownPreview.render("# 中文标题\n- **重点**\n> 引用\n```swift\nlet x = \"<script>\"\n```\n[网址](https://example.com)")
        XCTAssertTrue(output.string.contains("中文标题\n• 重点\n引用"))
        XCTAssertTrue(output.string.contains("let x = \"<script>\""))
        XCTAssertFalse(output.string.contains("```"))
        let titleFont = output.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertEqual(titleFont.pointSize, 28)
        let boldRange = (output.string as NSString).range(of: "重点")
        let boldFont = output.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        let linkRange = (output.string as NSString).range(of: "网址")
        XCTAssertEqual(output.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
    }

    @MainActor
    func testCodeFenceIsLiteralAndUnsafeLinksAreInactive() {
        let output = MarkdownPreview.render("~~~\n**literal**\n~~~\n[bad](javascript:alert)\nplain")
        XCTAssertTrue(output.string.contains("**literal**"))
        let range = (output.string as NSString).range(of: "bad")
        XCTAssertNil(output.attribute(.link, at: range.location, effectiveRange: nil))
        XCTAssertTrue(output.string.hasSuffix("plain\n"))
    }
    @MainActor
    func testEditorPreviewAndJSONUndo() throws {
        _ = NSApplication.shared
        let source = #"{"a":[1,2]}"#
        let editor = ClipboardEditor(text: source, name: "sample.json", report: { _ in })
        defer { editor.window.delegate = nil; editor.window.close() }
        let root = try XCTUnwrap(editor.window.contentView)
        let split = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSplitView }.first)
        let scroll = try XCTUnwrap(split.arrangedSubviews.first as? NSScrollView)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        editor.formatText()
        XCTAssertTrue(text.string.contains("\n"))
        XCTAssertTrue(editor.window.isDocumentEdited)
        XCTAssertTrue(text.undoManager?.canUndo == true)
        text.undoManager?.undo()
        XCTAssertEqual(text.string, source)
        let markdown = ClipboardEditor(text: "# Notes", name: "notes.md", report: { _ in })
        defer { markdown.window.delegate = nil; markdown.window.close() }
        let markdownRoot = try XCTUnwrap(markdown.window.contentView)
        let markdownSplit = try XCTUnwrap(markdownRoot.subviews.compactMap { $0 as? NSSplitView }.first)
        XCTAssertEqual(markdownSplit.arrangedSubviews.count, 2)
        markdownRoot.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(markdownSplit.arrangedSubviews[0].frame.width, 250)
        XCTAssertGreaterThan(markdownSplit.arrangedSubviews[1].frame.width, 250)
        func findPicker(_ view: NSView) -> NSSegmentedControl? {
            if let picker = view as? NSSegmentedControl { return picker }
            return view.subviews.compactMap(findPicker).first
        }
        let picker = try XCTUnwrap(findPicker(markdownRoot))
        picker.selectedSegment = 2; markdown.changeViewMode()
        XCTAssertEqual(markdownSplit.arrangedSubviews.count, 1)
        XCTAssertEqual(markdown.textView.string, "# Notes")
        picker.selectedSegment = 0; markdown.changeViewMode()
        XCTAssertEqual(markdownSplit.arrangedSubviews.count, 1)
        XCTAssertEqual((markdownSplit.arrangedSubviews.first as? NSScrollView)?.documentView, markdown.textView)

    }

}
