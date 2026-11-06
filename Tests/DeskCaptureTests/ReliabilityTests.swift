import XCTest
import AppKit
@testable import DeskCapture

final class ReliabilityTests: XCTestCase {
    @MainActor
    func testHotKeyDuplicateDeliveryAndRepeatsTriggerOnceUntilReleased() {
        let hotKey = GlobalHotKey()
        var presses = 0
        hotKey.onPress = { presses += 1 }
        // The foreground monitor, Carbon delivery, and held-key repeats
        // must all represent one press, even if the callback starts a capture.
        hotKey.handleKeyEvent(pressed: true)
        hotKey.handleKeyEvent(pressed: true)
        hotKey.handleKeyEvent(pressed: true)
        XCTAssertEqual(presses, 1)
        hotKey.handleKeyEvent(pressed: false)
        hotKey.handleKeyEvent(pressed: false)
        hotKey.handleKeyEvent(pressed: true)
        XCTAssertEqual(presses, 2)
        hotKey.unregister()
        hotKey.handleKeyEvent(pressed: true)
        XCTAssertEqual(presses, 3)
    }

    func testDamagedIndexRecoversImagesAndKeepsOriginalIndexBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let store = CaptureStore(directory: directory)
        let record = try store.add(ctx.makeImage()!, mode: .region)
        let corrupted = Data("invalid json".utf8)
        try corrupted.write(to: directory.appendingPathComponent("history.json"))
        let recovered = CaptureStore(directory: directory)
        XCTAssertEqual(recovered.records.count, 1)
        XCTAssertEqual(recovered.records.first?.filename, record.filename)
        try recovered.setText("recovered", for: recovered.records[0].id)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("history-recovery-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corrupted)
    }
    @MainActor
    func testCaptureTimeoutReturnsFailureInsteadOfHanging() async throws {
        do {
            let _: Int = try await captureWithTimeout(0.01) {
                try await Task.sleep(for: .milliseconds(100)); return 42
            }
            XCTFail("Should time out")
        } catch { XCTAssertEqual(error.localizedDescription, L10n.text("屏幕捕获没有及时响应。请确认系统权限授予的是当前 DeskCapture，并重启 App 后重试。")) }
    }
    @MainActor
    func testCaptureCompletesBeforeTimeout() async throws {
        let value = try await captureWithTimeout(0.5) { 42 }
        XCTAssertEqual(value, 42)
    }
    func testCustomShortcutSerializationPreservesModifiersAndKeyCode() throws {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
        let binding = try XCTUnwrap(HotKeyBinding(event: event))
        let decoded = try JSONDecoder().decode(HotKeyBinding.self, from: JSONEncoder().encode(binding))
        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(decoded.flags, [.command, .option])
        XCTAssertEqual(decoded.keyCode, 40)
    }
    @MainActor
    func testPendingTextIsCommittedBeforeExportAndStepNumberCanUndo() throws {
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let document = AnnotationDocument(image: ctx.makeImage()!)
        document.commitPendingText = { [weak document] in
            guard let document else { return }; document.commitPendingText = nil
            document.add(document.makeMark(tool: .text, points: [CGPoint(x: 0.2, y: 0.3)], text: "DeskCapture"))
        }
        XCTAssertNotNil(document.render())
        XCTAssertEqual(document.marks.first?.text, "DeskCapture")
        document.add(document.makeMark(tool: .step, points: [CGPoint(x: 0.5, y: 0.5)]))
        XCTAssertEqual(document.marks.last?.number, 1)
        document.undo(); XCTAssertEqual(document.marks.count, 1)
        document.redo(); XCTAssertEqual(document.marks.count, 2)
    }
}
