import XCTest
import AppKit
@testable import DeskCapture

final class LocalWorkflowTests: XCTestCase {
    func testResizeThenRotatePreservesSourceAndReturnsExpectedDimensions() async throws {
        let source = WorkflowCorpus.texture(width: 80, height: 40, seed: 42)
        let original = source.dataProvider!.data! as Data
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [.init(kind: .resize, value: 16), .init(kind: .rotate, value: 1)]
        let output = try await LocalWorkflowProcessor.run(source, recipe: recipe)
        XCTAssertEqual(output.image.width, 8); XCTAssertEqual(output.image.height, 16)
        XCTAssertEqual(output.completedSteps, 2); XCTAssertNil(output.text)
        XCTAssertEqual(source.dataProvider!.data! as Data, original)
    }
    func testInvalidOrderAndParametersAreRejectedBeforeAnyProcessing() {
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [.init(kind: .ocr), .init(kind: .resize, value: 100)]
        XCTAssertThrowsError(try recipe.validate())
        recipe.steps = [.init(kind: .resize, value: Int.max)]; XCTAssertThrowsError(try recipe.validate())
        recipe.steps = [.init(kind: .beautify)]; XCTAssertThrowsError(try recipe.validate())
        recipe.steps = []; XCTAssertThrowsError(try recipe.validate())
        recipe.steps = [.init(kind: .rotate, value: 1)]; recipe.version = 999
        XCTAssertThrowsError(try recipe.validate())
    }
    func testCancellationAtStepBoundaryProducesNoDeliverable() async throws {
        let source = WorkflowCorpus.texture(width: 80, height: 40, seed: 7), original = source.dataProvider!.data! as Data
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .resize, value: 32), .init(kind: .rotate, value: 1)]
        do {
            _ = try await LocalWorkflowProcessor.run(source, recipe: recipe, progress: { _, _ in withUnsafeCurrentTask { $0?.cancel() } })
            XCTFail("Cancelled workflow delivered a result")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(source.dataProvider!.data! as Data, original)
    }
    func testPipelineFailureDoesNotAlterSource() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let source = try XCTUnwrap(context.makeImage()), bytes = source.dataProvider!.data! as Data
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .trim, value: 8)]
        do { _ = try await LocalWorkflowProcessor.run(source, recipe: recipe); XCTFail("Blank trim should fail explicitly") } catch { }
        XCTAssertEqual(source.dataProvider!.data! as Data, bytes)
    }
    func testLibraryImportDoesNotOverwriteExistingRecipeOrSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-workflow-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalWorkflowLibrary(directory: root.appendingPathComponent("library")), recipe = LocalWorkflowRecipe()
        try await library.save(recipe)
        let file = root.appendingPathComponent("input.deskflow"), bytes = try LocalWorkflowLibrary.encode(recipe)
        try bytes.write(to: file)
        let imported = try await library.importFile(file)
        XCTAssertNotEqual(imported.id, recipe.id); XCTAssertEqual(try Data(contentsOf: file), bytes)
        let values = try await library.list(); XCTAssertEqual(values.count, 2)
        var invalid = recipe; invalid.steps = []
        do { try await library.save(invalid); XCTFail("Invalid update accepted") } catch { }
        let kept = try Data(contentsOf: root.appendingPathComponent("library/\(recipe.id).deskflow"))
        XCTAssertEqual(try LocalWorkflowLibrary.decode(kept).steps, recipe.steps)
    }
    func testWorkflowURLOnlyAcceptsOneLocalIdentityAndNoPathsOrOutputCommands() throws {
        let id = UUID()
        let command = try XCTUnwrap(CaptureURLCommand(URL(string: "deskcapture://workflow?id=\(id)")!))
        guard case .workflow(let actual) = command else { return XCTFail("Valid workflow URL rejected") }
        XCTAssertEqual(actual, id)
        for raw in ["deskcapture://workflow?id=bad", "deskcapture://workflow?id=\(id)&id=\(id)",
                    "deskcapture://workflow?id=\(id)&run=1", "deskcapture://workflow/path", "deskcapture://workflow?output=/tmp/file", "deskcapture://workflow#fragment"] {
            XCTAssertNil(CaptureURLCommand(URL(string: raw)!), raw)
        }
    }
}
