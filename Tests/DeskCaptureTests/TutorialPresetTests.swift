import XCTest
import AppKit
@testable import DeskCapture

final class TutorialPresetTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-preset-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
    @MainActor func testCompletePresetRoundTripAndApplyingDoesNotChangeExistingMarks() throws {
        let document = AnnotationDocument(image: WorkflowCorpus.texture(width: 80, height: 60, seed: 1))
        document.add(document.makeMark(tool: .arrow, points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.5)]))
        let old = document.marks.map(\.points)
        var preset = TutorialPreset(name: "教程品牌")
        preset.layout = .landscape; preset.padding = 0.2; preset.palette = ["#336699", "#FFFFFF"]
        preset.annotation = SavedAnnotationStyle(name: "文字", tool: .text, document: document)
        preset.backgroundPNG = try TutorialPreset.backgroundData(WorkflowCorpus.texture(width: 40, height: 30, seed: 2))
        let restored = try TutorialPreset.decode(preset.encoded())
        XCTAssertEqual(restored.palette, preset.palette); XCTAssertEqual(restored.annotation?.fontSize, preset.annotation?.fontSize)
        XCTAssertEqual(try restored.background()?.width, 40)
        restored.annotation?.apply(to: document); document.tutorialPreset = restored
        XCTAssertEqual(document.marks.map(\.points), old)
        let reopened = try AnnotationDocument(projectData: document.projectData())
        XCTAssertEqual(reopened.tutorialPreset?.id, preset.id)
        XCTAssertEqual(reopened.tutorialPreset?.palette, preset.palette)
        XCTAssertEqual(reopened.tool, .text)
        XCTAssertEqual(reopened.fontSize, preset.annotation?.fontSize)
        XCTAssertEqual(reopened.marks.map(\.points), old)
    }
    @MainActor func testPresetWithoutMarksIsNotLostByAsyncHistorySave() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(directory: root)
        let source = WorkflowCorpus.texture(width: 40, height: 30, seed: 4)
        let document = AnnotationDocument(image: source)
        document.tutorialPreset = TutorialPreset(name: "仅配置")
        let record = try await store.addAsync(source, mode: .region, document: document)
        let filename = try XCTUnwrap(record.projectFilename)
        let restored = try AnnotationDocument(projectData: Data(contentsOf: root.appendingPathComponent(filename)))
        XCTAssertEqual(restored.tutorialPreset?.name, "仅配置")
        XCTAssertTrue(restored.marks.isEmpty)
    }
    func testInvalidParametersAndMalformedBackgroundAreRejected() throws {
        var preset = TutorialPreset(name: "valid")
        preset.padding = .nan; XCTAssertThrowsError(try preset.encoded())
        preset.padding = 0.2; preset.version = 99; XCTAssertThrowsError(try preset.encoded())
        preset.version = 1; preset.palette = ["#XYZ123"]; XCTAssertThrowsError(try preset.encoded())
        preset.palette = []; preset.backgroundPNG = Data("not an image".utf8); XCTAssertThrowsError(try preset.encoded())
        XCTAssertThrowsError(try TutorialPreset.decode(Data("{}".utf8)))
    }
    func testLibraryImportCreatesIndependentIdentityAndInvalidUpdatePreservesFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = TutorialPresetLibrary(directory: root.appendingPathComponent("library"))
        var preset = TutorialPreset(name: "original")
        try await library.save(preset)
        let file = root.appendingPathComponent("library/\(preset.id).deskpreset")
        let bytes = try Data(contentsOf: file)
        preset.padding = -1
        do { try await library.save(preset); XCTFail("Invalid preset saved") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let external = root.appendingPathComponent("import.deskpreset"); try bytes.write(to: external)
        let imported = try await library.importFile(external)
        XCTAssertNotEqual(imported.id, preset.id)
        let stored = try await library.list(); XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        try await library.remove(imported.id)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testLegacyPreservesParametersAndRejectsMissingBackground() throws {
        var old = BeautifyPreset(id: UUID(), name: "旧预设", style: .ocean, layout: .portrait, padding: 0.12, roundness: 0.3)
        let converted = try TutorialPreset.legacy(old, background: nil)
        XCTAssertEqual(converted.layout, old.layout); XCTAssertEqual(converted.padding, old.padding)
        old.backgroundFilename = "background.png"
        XCTAssertThrowsError(try TutorialPreset.legacy(old, background: nil))
    }
    @MainActor func testOldProjectWithoutPresetStillOpens() throws {
        let image = WorkflowCorpus.texture(width: 24, height: 18, seed: 3)
        let document = AnnotationDocument(image: image)
        let data = try document.projectData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "tutorialPreset")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try AnnotationDocument(projectData: old).tutorialPreset)
    }
}
