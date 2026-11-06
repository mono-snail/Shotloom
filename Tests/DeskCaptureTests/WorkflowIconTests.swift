import XCTest
import AppKit
@testable import DeskCapture

final class WorkflowIconTests: XCTestCase {
    func testSelectedIconSurvivesRecipeExportAndImport() throws {
        var recipe = LocalWorkflowRecipe()
        recipe.iconName = "paintpalette.fill"; recipe.inCaptureToolbar = true
        let restored = try LocalWorkflowLibrary.decode(LocalWorkflowLibrary.encode(recipe))
        XCTAssertEqual(restored.toolbarSymbol, "paintpalette.fill")
        XCTAssertEqual(restored.inCaptureToolbar, true)
    }
    func testOlderRecipesKeepTheirDefaultIconAndVisibilityPreference() throws {
        var recipe = LocalWorkflowRecipe(); recipe.iconName = nil; recipe.inCaptureToolbar = false
        let restored = try LocalWorkflowLibrary.decode(LocalWorkflowLibrary.encode(recipe))
        XCTAssertEqual(restored.toolbarSymbol, "bolt.fill")
        XCTAssertEqual(restored.inCaptureToolbar, false)
    }
    @MainActor func testNewRecipesAreReadyToAppearInCaptureToolbar() {
        let recipe = LocalWorkflowView.newRecipe()
        XCTAssertEqual(recipe.inCaptureToolbar, true)
        XCTAssertTrue(WorkflowIcon.symbols.contains(recipe.toolbarSymbol))
    }
    @MainActor func testPickerSymbolsAreAvailableOnCurrentMacOS() {
        for choice in WorkflowIcon.choices {
            XCTAssertNotNil(NSImage(systemSymbolName: choice.id, accessibilityDescription: nil), choice.id)
        }
    }
}
