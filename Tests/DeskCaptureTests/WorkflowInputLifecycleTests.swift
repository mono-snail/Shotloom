import XCTest
import AppKit
@testable import DeskCapture

final class WorkflowInputLifecycleTests: XCTestCase {
    @MainActor
    func testImmediateCancellationNeverStartsPickerOrReplacesSource() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-input-\(UUID())")
        let board = NSPasteboard(name: .init("workflow-input-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        board.setString("preserve", forType: .string)
        let app = AppCoordinator(store: CaptureStore(directory: directory), imagePasteboard: board, registerHotKeys: false)
        let image = WorkflowCorpus.texture(width: 32, height: 24, seed: 41)
        let run = LocalWorkflowRun(source: image)
        run.captureSelection(.region, app: app, recipe: LocalWorkflowRecipe())
        run.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(app.isCapturing); XCTAssertFalse(run.busy)
        XCTAssertTrue(run.source === image); XCTAssertNil(run.result)
        XCTAssertEqual(board.string(forType: .string), "preserve")
        XCTAssertTrue(app.store.records.isEmpty)
        XCTAssertFalse(app.confirmWorkflowInputForDiagnostics())
    }

    @MainActor
    func testInvalidRecipeFailsBeforeScreenPermissionOrInputSelection() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-input-\(UUID())")
        let board = NSPasteboard(name: .init("workflow-input-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let app = AppCoordinator(store: CaptureStore(directory: directory), imagePasteboard: board, registerHotKeys: false)
        let image = WorkflowCorpus.texture(width: 32, height: 24, seed: 42)
        let run = LocalWorkflowRun(source: image)
        var recipe = LocalWorkflowRecipe(); recipe.steps = []
        run.captureSelection(.window, app: app, recipe: recipe)
        for _ in 0..<200 where run.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(run.busy); XCTAssertNotNil(run.error)
        XCTAssertFalse(app.isCapturing); XCTAssertTrue(run.source === image)
        XCTAssertNil(run.result); XCTAssertTrue(app.store.records.isEmpty)
    }
}
