import XCTest
import AppKit
@testable import DeskCapture

final class RepairSubjectCompositionTests: XCTestCase {
    private func fixture() throws -> CGImage {
        var bytes = [UInt8](repeating:0xCD,count:24*3)
        for y in 0..<3 { for x in 0..<4 {
            let i=y*24+x*4
            bytes[i]=UInt8(91+x);bytes[i+1]=UInt8(133+y);bytes[i+2]=53;bytes[i+3]=128
        } }
        return try XCTUnwrap(CGImage(width:4,height:3,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:24,
            space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.relativeColorimetric))
    }
    func testReplacingSubjectMaskDoesNotCompoundAlphaOrLoseBasePixels() throws {
        let base=try fixture(), composition=RepairSubjectComposition(base:base)
        let weights=RepairRasterMask(width:4,height:3,values:Array(repeating:127,count:12))
        let first=try composition.applying(weights).dataProvider!.data! as Data
        let second=try composition.applying(weights).dataProvider!.data! as Data
        XCTAssertEqual(first,second);XCTAssertEqual(first[3],64)
        let restored=try composition.applying(.init(width:4,height:3,values:Array(repeating:0,count:12)))
        XCTAssertEqual(restored.dataProvider!.data! as Data,base.dataProvider!.data! as Data)
    }
    func testManualOverrideSurvivesNewSubjectMaskWithoutColorOrAlphaDrift() async throws {
        let base=try fixture(), before=base.dataProvider!.data! as Data
        var composition=RepairSubjectComposition(base:base)
        let removed=try composition.applying(.init(width:4,height:3,values:Array(repeating:255,count:12)))
        let selection=RepairSelection(strokes:[.init(points:[.init(x:0.625,y:0.5)],diameter:2,erase:false)],feather:0)
        let manual=try await LocalImageRepair.renderWithMask(base:removed,original:base,selection:selection,method:.restore,anchor:nil,modelID:nil)
        composition=try composition.addingOverride(image:manual.image,mask:manual.mask)
        let edited=manual.image.dataProvider!.data! as Data
        XCTAssertGreaterThan(edited[35],0)
        for weights in [Array(repeating:UInt8(255),count:12),Array(repeating:UInt8(127),count:12),Array(repeating:UInt8(0),count:12)] {
            let output=try composition.applying(.init(width:4,height:3,values:weights))
            let bytes=output.dataProvider!.data! as Data
            XCTAssertEqual(bytes[32..<36],edited[32..<36])
            XCTAssertEqual(output.colorSpace?.name,base.colorSpace?.name)
            for y in 0..<3 { XCTAssertEqual(bytes[y*24+16..<y*24+24],before[y*24+16..<y*24+24]) }
        }
        XCTAssertEqual(base.dataProvider!.data! as Data,before)
    }
    func testOverrideRejectsMismatchedDimensions() throws {
        let base=try fixture(), composition=RepairSubjectComposition(base:base)
        XCTAssertThrowsError(try composition.addingOverride(image:base,mask:.init(width:Int.max,height:Int.max,values:[])))
        XCTAssertThrowsError(try composition.applying(.init(width:4,height:3,values:[])))
    }
    @MainActor
    func testSubjectPreviewAndRepeatedMasksUseOneNativeInstanceNamespace() async throws {
        let source=try QualityDiagnostics.cleanupFixture()
        // Keep native work and large mask equality off the main actor.
        let report=try await Task.detached { () async throws -> ([Int],[Int],Bool,Int,Bool) in
            let analysis=ForegroundSubjectAnalysis(source:source)
            let subjects=try await analysis.subjects()
            let first=try XCTUnwrap(subjects.first), selected=IndexSet(integer:first.id)
            let mask=try await analysis.erasure(instances:selected)
            let repeatMask=try await analysis.erasure(instances:selected)
            let previews=try await analysis.subjects()
            let count=await analysis.diagnosticInferenceCount
            var rejected=false
            do { _ = try await analysis.erasure(instances:IndexSet(integer:1_000_000)) }
            catch { rejected = !(error is CancellationError) }
            return (subjects.map(\.id),previews.map(\.id),mask.values==repeatMask.values && mask.width==source.width && mask.height==source.height,count,rejected)
        }.value
        XCTAssertEqual(report.0,report.1);XCTAssertTrue(report.2)
        XCTAssertEqual(report.3,1);XCTAssertTrue(report.4,"Unknown instance must be rejected without cancellation")
    }
    @MainActor
    func testNativeScaledMaskMatchesIndependentMaskedImageOnAsymmetricFixture() async throws {
        let fruit=try QualityDiagnostics.cleanupFixture()
        let report=try await Task.detached { () throws -> (Int,Int,Double,Int) in
            let c=try XCTUnwrap(CGContext(data:nil,width:900,height:900,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            c.setFillColor(CGColor(gray:0.95,alpha:1));c.fill(CGRect(x:0,y:0,width:900,height:900))
            c.draw(fruit,in:CGRect(x:0,y:0,width:800,height:600))
            let source=try XCTUnwrap(c.makeImage()), before=source.dataProvider!.data! as Data
            let reference=try CaptureImageCleanup.foreground(source)
            let mask=try CaptureImageCleanup.foregroundErasureMask(source)
            let output=try RepairSubjectComposition(base:source).applying(mask)
            func rgba(_ image:CGImage) throws -> [UInt8] {
                let context=try XCTUnwrap(CGContext(data:nil,width:900,height:900,bitsPerComponent:8,bytesPerRow:900*4,
                    space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.setBlendMode(.copy);context.draw(image,in:CGRect(x:0,y:0,width:900,height:900))
                let ptr=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
                return Array(UnsafeBufferPointer(start:ptr,count:900*900*4))
            }
            let expected=try rgba(reference), actual=try rgba(output)
            var total=0, maximum=0
            for pixel in 0..<(900*900) { let delta=abs(Int(expected[pixel*4+3])-Int(actual[pixel*4+3]));total += delta;maximum=max(maximum,delta) }
            XCTAssertEqual(source.dataProvider!.data! as Data,before)
            return (Int(actual[(625*900+400)*4+3]),Int(actual[(100*900+400)*4+3]),Double(total)/810_000,maximum)
        }.value
        XCTAssertGreaterThan(report.0,200);XCTAssertEqual(report.1,0)
        XCTAssertLessThanOrEqual(report.2,1);XCTAssertLessThanOrEqual(report.3,4)
    }
}
