import XCTest
import AppKit
@testable import DeskCapture

final class PasteCompatibilityTests: XCTestCase {
    @MainActor
    func testNativeRichTextPasteKeepsTransparencyAndRetinaOutputSize() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-paste-test-\(UUID())")
        let board = NSPasteboard(name: NSPasteboard.Name("DeskCapture-paste-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let app = AppCoordinator(store: CaptureStore(directory: directory), imagePasteboard: board, registerHotKeys: false)
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 80, height: 40))
        let source = try XCTUnwrap(context.makeImage())
        let previous = AppPreferences.standard.object(forKey: "clipboardLogicalSize")
        defer {
            if let previous { AppPreferences.standard.set(previous, forKey: "clipboardLogicalSize") }
            else { AppPreferences.standard.removeObject(forKey: "clipboardLogicalSize") }
        }
        for logical in [false, true] {
            AppPreferences.standard.set(logical, forKey: "clipboardLogicalSize")
            app.copy(source, backingScale: 2)
            await app.waitForPendingImageCopy()
            let png = try XCTUnwrap(board.data(forType: .png)), tiff = try XCTUnwrap(board.data(forType: .tiff))
            for data in [png, tiff] {
                let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
                XCTAssertEqual(image.width, logical ? 60 : 120); XCTAssertEqual(image.height, logical ? 40 : 80)
                let bitmap = NSBitmapImageRep(cgImage: image)
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.001)
            }
            let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
            text.isRichText = true; text.importsGraphics = true
            XCTAssertTrue(text.readSelection(from: board, type: .tiff))
            let storage = try XCTUnwrap(text.textStorage)
            XCTAssertEqual(storage.length, 1)
            let attachment = try XCTUnwrap(storage.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            let pasted = attachment.image ?? (attachment.attachmentCell as? NSCell)?.image
                ?? attachment.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) }
            let image = try XCTUnwrap(pasted)
            XCTAssertEqual(image.size.width, logical ? 60 : 120, accuracy: 0.1)
            XCTAssertEqual(image.size.height, logical ? 40 : 80, accuracy: 0.1)
            XCTAssertEqual(source.width, 120); XCTAssertEqual(source.height, 80)
        }
        XCTAssertTrue(app.store.records.isEmpty)
    }
}
