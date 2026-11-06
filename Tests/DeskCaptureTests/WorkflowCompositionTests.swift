import XCTest
import AppKit
@testable import DeskCapture

final class WorkflowCompositionTests: XCTestCase {
    func testLegacyRecipeLoadsWithPreviewOnlyAndNoToolbarButton() throws {
        let data = Data("""
        {"version":1,"id":"64848008-3EC5-4222-883C-300B16E063B9","name":"旧流程","steps":[{"id":"90A6D0EA-ED80-4B90-9DE4-E58BD78A986E","kind":"resize","value":2400}]}
        """.utf8)
        let recipe = try LocalWorkflowLibrary.decode(data)
        XCTAssertEqual(recipe.delivery.kind, .preview)
        XCTAssertNotEqual(recipe.inCaptureToolbar, true)
        XCTAssertEqual(recipe.steps.first?.value, 2400)
    }

    func testWatermarkThenBeautifyRoundTripPreservesParametersAndSource() async throws {
        let source = WorkflowCorpus.texture(width: 320, height: 180, seed: 62)
        let original = source.dataProvider!.data! as Data
        let watermark = ImageWatermark(enabled: true, text: "Example", fontSize: 20, angle: -25, opacity: 0.4)
        let appearance = WorkflowAppearance(style: .paper, layout: .square, padding: 0.1, roundness: 0.2)
        var recipe = LocalWorkflowRecipe()
        recipe.name = "发布截图"; recipe.inCaptureToolbar = true
        recipe.steps = [.init(kind: .watermark, watermark: watermark), .init(kind: .beautify, appearance: appearance)]
        recipe.output = .init(kind: .saveImage, format: .jpeg, prefix: "发布")
        let restored = try LocalWorkflowLibrary.decode(LocalWorkflowLibrary.encode(recipe))
        XCTAssertEqual(restored, recipe)
        let output = try await LocalWorkflowProcessor.run(source, recipe: restored)
        let plain = try CaptureBeautifier.render(source, style: .paper, paddingPercent: 0.1, roundness: 0.2, layout: .square)
        XCTAssertEqual(output.image.width, output.image.height)
        XCTAssertEqual(output.image.width, plain.width)
        XCTAssertNotEqual(output.image.dataProvider!.data! as Data, plain.dataProvider!.data! as Data)
        XCTAssertEqual(source.dataProvider!.data! as Data, original)
    }

    func testTextDeliveryCannotRunWithoutTerminalRecognition() throws {
        var recipe = LocalWorkflowRecipe()
        recipe.output = .init(kind: .copyText)
        XCTAssertThrowsError(try recipe.validate())
        recipe.steps = [.init(kind: .ocr)]
        XCTAssertNoThrow(try recipe.validate())
        recipe.steps.append(.init(kind: .rotate, value: 1))
        XCTAssertThrowsError(try recipe.validate())
    }

    func testGeneratedFolderDeliveryNeverOverwritesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-flow-output-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("existing.png"), sentinel = Data("existing destination".utf8)
        try sentinel.write(to: target)
        let result = LocalWorkflowResult(image: WorkflowCorpus.texture(width: 24, height: 16, seed: 8), text: nil, completedSteps: 1)
        XCTAssertThrowsError(try WorkflowFileDelivery.write(result, output: .init(kind: .saveImage), to: target, replaceExisting: false))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["existing.png"])
    }
}
