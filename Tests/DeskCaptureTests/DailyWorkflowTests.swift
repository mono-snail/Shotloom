import XCTest
import AppKit
@testable import DeskCapture

final class DailyWorkflowTests: XCTestCase {
    private func image() -> CGImage {
        let c = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor.red.cgColor); c.fill(CGRect(x: 10, y: 10, width: 100, height: 60))
        return c.makeImage()!
    }
    func testClipboardLogicalSizeUsesSourceDisplayScaleWithoutChangingOriginal() throws {
        let original = image()
        let retina = try CapturePreferences.clipboardImage(original, logicalSize: true, backingScale: 2)
        XCTAssertEqual(retina.width, 60); XCTAssertEqual(retina.height, 40)
        XCTAssertEqual(original.width, 120)
        XCTAssertEqual(try CapturePreferences.clipboardImage(original, logicalSize: true, backingScale: 1).width, 120)
        XCTAssertEqual(try CapturePreferences.clipboardImage(original, logicalSize: false, backingScale: 2).width, 120)
        XCTAssertEqual(try CapturePreferences.clipboardImage(original, logicalSize: true, backingScale: .infinity).width, 120)
    }
    func testWindowBackdropAndShadowKeepAlphaAndAddPadding() throws {
        let transparent = try XCTUnwrap(CapturePreferences.windowImage(image(), backdrop: .transparent, shadow: false, scale: 2))
        XCTAssertEqual((try XCTUnwrap(transparent.dataProvider?.data) as Data)[3], 0)
        let white = try XCTUnwrap(CapturePreferences.windowImage(image(), backdrop: .white, shadow: false, scale: 2))
        XCTAssertEqual((try XCTUnwrap(white.dataProvider?.data) as Data)[3], 255)
        XCTAssertEqual(CapturePixelColor.hex(white, at: .zero), "#FFFFFF")
        let shadow = try XCTUnwrap(CapturePreferences.windowImage(image(), backdrop: .transparent, shadow: true, scale: 2))
        XCTAssertEqual(shadow.width, 192); XCTAssertEqual(shadow.height, 152)
    }
    func testSensitiveKindsAndCardChecksRejectOrdinaryNumbers() {
        XCTAssertTrue(SensitiveContent.kinds(in: "person@example.com").contains(.email))
        XCTAssertTrue(SensitiveContent.kinds(in: "13800138000").contains(.phone))
        XCTAssertTrue(SensitiveContent.kinds(in: "+1 202 555 0123").contains(.phone))
        XCTAssertTrue(SensitiveContent.kinds(in: "11010519491231002X").contains(.identity))
        XCTAssertTrue(SensitiveContent.kinds(in: "4111 1111 1111 1111").contains(.payment))
        XCTAssertFalse(SensitiveContent.kinds(in: "4111 1111 1111 1112").contains(.payment))
        XCTAssertFalse(SensitiveContent.kinds(in: "0000000000000000").contains(.payment))
        XCTAssertTrue(SensitiveContent.kinds(in: "ghp_" + String(repeating: "x", count: 30)).contains(.credential))
        XCTAssertTrue(SensitiveContent.kinds(in: "DeskCapture 0.7 2026-10-12").isEmpty)
    }
    @MainActor func testSelectedSensitiveLinesAreOpaqueAndUndoAsOneOperation() throws {
        let d = AnnotationDocument(image: image())
        let a = OCRLine(text: "person@example.com", bounds: CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.2), confidence: 1)
        let b = OCRLine(text: "not selected", bounds: CGRect(x: 0.2, y: 0.7, width: 0.5, height: 0.1), confidence: 1)
        d.ocrLines = [a, b]
        XCTAssertEqual(d.redactOCRLines([a]), 1)
        XCTAssertEqual(d.marks.count, 1)
        XCTAssertEqual(d.marks.first?.tool, .redact)
        let rendered = try XCTUnwrap(d.render())
        XCTAssertEqual(CapturePixelColor.hex(rendered, at: CGPoint(x: 60, y: 40)), "#000000")
        d.undo(); XCTAssertTrue(d.marks.isEmpty)
    }
    @MainActor func testLocalUsageIsOptInAndAcceptsOnlyFixedFeatureKeys() {
        let name = "DeskCapture-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let usage = LocalUsage(defaults: defaults)
        usage.record("capture.region"); XCTAssertTrue(usage.counts.isEmpty)
        defaults.set(true, forKey: "localUsageEnabled")
        usage.record("capture.region"); usage.record("private user text")
        XCTAssertEqual(usage.counts, ["capture.region": 1])
        XCTAssertEqual(LocalUsage(defaults: defaults).counts, usage.counts)
        usage.clear(); XCTAssertTrue(LocalUsage(defaults: defaults).counts.isEmpty)
    }
    @MainActor func testHistoryRetainsSourceScaleAndOldRecordsStillDecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let record = try store.add(image(), mode: .region, backingScale: 2)
        XCTAssertEqual(CaptureStore(directory: directory).records.first?.backingScale, 2)
        let document = AnnotationDocument(image: image()); document.backingScale = 2
        XCTAssertEqual(try AnnotationDocument(projectData: document.projectData()).backingScale, 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "backingScale")
        XCTAssertNil(try JSONDecoder().decode(CaptureRecord.self, from: JSONSerialization.data(withJSONObject: object)).backingScale)
    }
}
