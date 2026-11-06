import XCTest
import AppKit
@testable import DeskCapture

final class ClipboardTests: XCTestCase {
    func testTextAndPathsAreDistinct() {
        XCTAssertNil(ClipboardContent.filePath("Some notes\n/home/user/file.txt"))
        XCTAssertNil(ClipboardContent.filePath("https://example.com/a.pdf"))
        XCTAssertEqual(ClipboardContent.filePath("\"/tmp/my notes.md\"")?.path, "/tmp/my notes.md")
        XCTAssertEqual(ClipboardContent.filePath("file:///tmp/my%20notes.md")?.path, "/tmp/my notes.md")
        XCTAssertTrue(ClipboardContent.filePath("~/notes.txt")?.path.hasSuffix("/notes.txt") == true)
    }
    func testClipboardFilesTakePriorityOverText() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([NSURL(fileURLWithPath: "/tmp/notes.md")])
        board.setString("fallback", forType: .string)
        guard case .files(let files) = try ClipboardContent.read(board) else { return XCTFail("Expected file") }
        XCTAssertEqual(files.first?.path, "/tmp/notes.md")
    }
    func testPlainTextAndUnsupportedClipboard() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertThrowsError(try ClipboardContent.read(board))
        board.setString("# Notes\n你好", forType: .string)
        guard case .text(let text) = try ClipboardContent.read(board) else { return XCTFail("Expected text") }
        XCTAssertEqual(text, "# Notes\n你好")
    }
    func testSupportedFileRouting() {
        for ext in ["txt", "MD", "markdown", "json"] { XCTAssertEqual(ClipboardContent.kind(URL(fileURLWithPath: "/tmp/a.\(ext)")), .text) }
        XCTAssertEqual(ClipboardContent.kind(URL(fileURLWithPath: "/tmp/a.pdf")), .pdf)
        XCTAssertEqual(ClipboardContent.kind(URL(fileURLWithPath: "/tmp/a.png")), .image)
        XCTAssertEqual(ClipboardContent.kind(URL(fileURLWithPath: "/tmp/a.mp4")), .video)
        XCTAssertEqual(ClipboardContent.kind(URL(fileURLWithPath: "/tmp/a.deskcap")), .project)
        XCTAssertNil(ClipboardContent.kind(URL(fileURLWithPath: "/tmp/a.zip")))
    }
    func testTextFileDecoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# 中文笔记\n- 内容".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ClipboardContent.loadText(url), "# 中文笔记\n- 内容")
    }
}
