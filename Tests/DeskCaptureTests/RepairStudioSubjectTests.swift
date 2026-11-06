import XCTest
import AppKit
@testable import DeskCapture

@MainActor
final class RepairStudioSubjectTests: XCTestCase {
    private var brush: RepairSelection {
        .init(strokes:[.init(points:[.init(x:0.625,y:0.5)],diameter:2,erase:false)],feather:0)
    }
    private func settle(_ model: RepairStudioModel) async throws {
        let task=try XCTUnwrap(model.pendingTaskForDiagnostics)
        await task.value
        XCTAssertFalse(model.busy);XCTAssertNil(model.error)
    }
    func testInvalidSubjectIDsCannotInvokeFoundationOrChangeCurrentImage() {
        let model=RepairStudioModel(image:WorkflowCorpus.texture(width:4,height:3,seed:81))
        let before=model.image.dataProvider!.data! as Data
        model.subjectMaskForDiagnostics={ _, _ in
            XCTFail("Invalid identifiers must not start mask generation")
            return .init(width:4,height:3,values:[UInt8](repeating:0,count:12))
        }
        for selected: Set<Int> in [[],[0],[-1],[Int.max]] {
            model.background(selected)
            XCTAssertNotNil(model.error);XCTAssertFalse(model.busy)
            XCTAssertNil(model.pendingTaskForDiagnostics)
            XCTAssertEqual(model.image.dataProvider!.data! as Data,before)
            XCTAssertFalse(model.canUndo);XCTAssertFalse(model.canRedo)
        }
    }
    func testSubjectReplacementKeepsPriorEditsAndRestoresExcludedSubjectPixels() async throws {
        let source=WorkflowCorpus.texture(width:4,height:3,seed:19), model=RepairStudioModel(image:source)
        let original=source.dataProvider!.data! as Data
        model.repair(brush,method:.transparent,anchor:nil,modelID:nil)
        try await settle(model)
        let edited=model.image.dataProvider!.data! as Data
        XCTAssertEqual(Array(edited[24..<28]),[0,0,0,0])
        model.subjectMaskForDiagnostics={ _, selected in
            var values=[UInt8](repeating:0,count:12)
            if selected.contains(1) { values[0]=255 }
            return .init(width:4,height:3,values:values)
        }
        model.background([1]);try await settle(model)
        let first=model.image.dataProvider!.data! as Data
        XCTAssertEqual(Array(first[0..<4]),[0,0,0,0])
        XCTAssertEqual(Array(first[24..<28]),[0,0,0,0])
        model.background([2]);try await settle(model)
        XCTAssertEqual(model.image.dataProvider!.data! as Data,edited)
        model.undo();XCTAssertEqual(model.image.dataProvider!.data! as Data,first)
        model.redo();XCTAssertEqual(model.image.dataProvider!.data! as Data,edited)
        XCTAssertEqual(source.dataProvider!.data! as Data,original)
    }
    func testManualEdgeAndItsCompositionStateSurviveUndoRedoAndSubjectChanges() async throws {
        let source=WorkflowCorpus.texture(width:4,height:3,seed:31), model=RepairStudioModel(image:source)
        model.subjectMaskForDiagnostics={ _, _ in .init(width:4,height:3,values:[UInt8](repeating:255,count:12)) }
        model.background([1]);try await settle(model)
        let removed=model.image.dataProvider!.data! as Data
        XCTAssertTrue(removed.allSatisfy { $0 == 0 })
        model.repair(brush,method:.restore,anchor:nil,modelID:nil);try await settle(model)
        let manual=model.image.dataProvider!.data! as Data
        XCTAssertGreaterThan(manual[27],0)
        model.background([2]);try await settle(model)
        XCTAssertEqual(model.image.dataProvider!.data! as Data,manual)
        model.undo();model.undo()
        XCTAssertEqual(model.image.dataProvider!.data! as Data,removed)
        model.redo()
        XCTAssertEqual(model.image.dataProvider!.data! as Data,manual)
        model.background([1]);try await settle(model)
        XCTAssertEqual(model.image.dataProvider!.data! as Data,manual)
    }
    func testCancelledOldSubjectMaskCannotReplaceNewerImageOrUndoState() async throws {
        let model=RepairStudioModel(image:WorkflowCorpus.texture(width:4,height:3,seed:77))
        let began=expectation(description:"Old native mask started"), release=DispatchSemaphore(value:0)
        defer { release.signal() }
        model.subjectMaskForDiagnostics={ _, _ in
            began.fulfill()
            guard release.wait(timeout:.now()+5) == .success else { throw CaptureError.message("Fixture timeout") }
            return .init(width:4,height:3,values:[UInt8](repeating:255,count:12))
        }
        model.background([1])
        let old=try XCTUnwrap(model.pendingTaskForDiagnostics)
        await fulfillment(of:[began],timeout:3)
        model.reset()
        model.subjectMaskForDiagnostics={ _, _ in .init(width:4,height:3,values:[UInt8](repeating:0,count:12)) }
        model.background([2]);try await settle(model)
        let current=model.image.dataProvider!.data! as Data, undo=model.canUndo, redo=model.canRedo
        release.signal();await old.value
        XCTAssertEqual(model.image.dataProvider!.data! as Data,current)
        XCTAssertEqual(model.canUndo,undo);XCTAssertEqual(model.canRedo,redo)
        XCTAssertNil(model.error);XCTAssertFalse(model.busy)
    }
}
