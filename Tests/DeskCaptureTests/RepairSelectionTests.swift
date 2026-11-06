import XCTest
@testable import DeskCapture

final class RepairSelectionTests: XCTestCase {
    func testMaskUsesTopLeftCoordinatesAndErasesSelection() throws {
        let stroke=RepairStroke(points:[CGPoint(x:0.25,y:0.25)],diameter:12,erase:false)
        var selection=RepairSelection(strokes:[stroke],feather:0)
        let first=try selection.raster(width:40,height:40)
        XCTAssertEqual(first.values[10*40+10],255)
        XCTAssertEqual(first.values[30*40+10],0)
        var eraser=stroke;eraser.erase=true;selection.strokes.append(eraser)
        XCTAssertNil(try selection.raster(width:40,height:40).bounds)
    }
    func testRawPixelsOutsideMaskArePreservedExactly() throws {
        let base=WorkflowCorpus.texture(width:64,height:48,seed:42)
        let patch=WorkflowCorpus.texture(width:20,height:20,seed:73)
        let mask=try RepairSelection(strokes:[.init(points:[CGPoint(x:0.4,y:0.5)],diameter:12,erase:false)],feather:3).raster(width:64,height:48)
        let rect=try XCTUnwrap(mask.bounds)
        let output=try RepairPixelComposite.apply(base:base,patch:patch,rect:rect,mask:mask)
        let before=base.dataProvider!.data! as Data, after=output.dataProvider!.data! as Data
        for y in 0..<48 { for x in 0..<64 where mask.values[y*64+x]==0 {
            for c in 0..<4 { XCTAssertEqual(before[y*base.bytesPerRow+x*4+c],after[y*output.bytesPerRow+x*4+c]) }
        } }
    }
    func testStrokeBudgetsAndInvalidCoordinatesAreRejected() {
        XCTAssertThrowsError(try RepairSelection(strokes:[.init(points:[CGPoint(x:1.2,y:0)],diameter:20,erase:false)],feather:4).raster(width:100,height:100))
        XCTAssertThrowsError(try RepairSelection().raster(width:100_000,height:100_000))
    }
    func testRestoringMaskedRegionDoesNotChangeOutsidePixels() async throws {
        let original=WorkflowCorpus.texture(width:80,height:60,seed:42)
        let changed=WorkflowCorpus.texture(width:80,height:60,seed:71)
        let selection=RepairSelection(strokes:[.init(points:[CGPoint(x:0.5,y:0.5)],diameter:20,erase:false)],feather:0)
        let output=try await LocalImageRepair.render(base:changed,original:original,selection:selection,method:.restore,anchor:nil,modelID:nil)
        let mask=try selection.raster(width:80,height:60), bytes=output.dataProvider!.data! as Data
        let a=original.dataProvider!.data! as Data,b=changed.dataProvider!.data! as Data
        for y in 0..<60 { for x in 0..<80 {
            let expected=mask.values[y*80+x]>0 ? a : b
            for c in 0..<4 { XCTAssertEqual(bytes[y*output.bytesPerRow+x*4+c],expected[y*changed.bytesPerRow+x*4+c]) }
        } }
    }
}
