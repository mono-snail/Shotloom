import XCTest
import AppKit
@testable import DeskCapture

final class WorkflowLivePreviewTests: XCTestCase {
    func testEditingEarlierToolInvalidatesCachedFollowingResults() async throws {
        let source = WorkflowCorpus.texture(width: 320, height: 180, seed: 63)
        let renderer = WorkflowPreviewRenderer()
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [
            .init(kind: .watermark, watermark: .init(enabled: true, text: "Example", angle: -30, opacity: 0.15)),
            .init(kind: .beautify, appearance: .init(style: .paper))
        ]
        let initial = try await renderer.render(source, steps: recipe.steps)
        recipe.steps[0].watermark?.opacity = 0.5
        let edited = try await renderer.render(source, steps: recipe.steps)
        let delivered = try await LocalWorkflowProcessor.run(source, recipe: recipe)
        XCTAssertNotEqual(initial.image.dataProvider!.data! as Data, edited.image.dataProvider!.data! as Data)
        XCTAssertEqual(edited.image.width, delivered.image.width)
        XCTAssertEqual(edited.image.dataProvider!.data! as Data, delivered.image.dataProvider!.data! as Data)
    }

    func testChoosingAnotherSourceCannotReusePreviousImageCache() async throws {
        let renderer = WorkflowPreviewRenderer(), first = WorkflowCorpus.texture(width: 320, height: 180, seed: 64)
        let second = WorkflowCorpus.texture(width: 320, height: 180, seed: 65)
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [.init(kind: .beautify, appearance: .init(style: .graphite))]
        _ = try await renderer.render(first, steps: recipe.steps)
        let preview = try await renderer.render(second, steps: recipe.steps)
        let expected = try await LocalWorkflowProcessor.run(second, recipe: recipe)
        XCTAssertEqual(preview.image.dataProvider!.data! as Data, expected.image.dataProvider!.data! as Data)
    }

    func testPreviewDefersInteractiveAndRecognitionToolsAndAllowsAnEmptyDraft() async throws {
        let source = WorkflowCorpus.texture(width: 160, height: 90, seed: 66), renderer = WorkflowPreviewRenderer()
        let empty = try await renderer.render(source, steps: [])
        XCTAssertEqual(empty.image.dataProvider!.data! as Data, source.dataProvider!.data! as Data)
        let result = try await renderer.render(source, steps: [.init(kind: .sensitiveReview), .init(kind: .ocr)])
        XCTAssertEqual(result.image.dataProvider!.data! as Data, source.dataProvider!.data! as Data)
        XCTAssertEqual(result.deferredTools.count, 2)
    }

    func testVisualToolCanBeRepeatedInTheUserSequence() async throws {
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [.init(kind: .beautify, appearance: .init(style: .paper)),
                        .init(kind: .beautify, appearance: .init(style: .graphite))]
        try recipe.validate()
        let result = try await LocalWorkflowProcessor.run(WorkflowCorpus.texture(width: 160, height: 90, seed: 67), recipe: recipe)
        XCTAssertEqual(result.completedSteps, 2)
        XCTAssertEqual(result.image.width, 320)
        XCTAssertEqual(result.image.height, 250)
    }
}
