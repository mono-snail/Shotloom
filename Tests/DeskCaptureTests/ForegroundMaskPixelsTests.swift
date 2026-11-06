import XCTest
import CoreVideo
@testable import DeskCapture

final class ForegroundMaskPixelsTests: XCTestCase {
    private func buffer(_ format: OSType, values: [Float]) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,3,2,format,nil,&result),kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer,[]),kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), stride = CVPixelBufferGetBytesPerRow(buffer)
        base.initializeMemory(as: UInt8.self,repeating: 0xFF,count: stride*2)
        for y in 0..<2 { for x in 0..<3 {
            if format == kCVPixelFormatType_OneComponent32Float {
                base.advanced(by:y*stride).assumingMemoryBound(to:Float.self)[x] = values[y*3+x]
            } else if format == kCVPixelFormatType_OneComponent8 {
                base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[x] = UInt8(values[y*3+x])
            }
        } }
        return buffer
    }
    func testFloatMaskPreservesAsymmetricRowsAndIgnoresNaNPadding() throws {
        let source = try buffer(kCVPixelFormatType_OneComponent32Float,values:[1,0.5,0,0.25,0.75,1])
        XCTAssertEqual(try ForegroundMaskPixels.erasure(source,width:3,height:2).values,[0,127,255,191,64,0])
    }
    func testByteMaskUsesExactKeepWeights() throws {
        let source = try buffer(kCVPixelFormatType_OneComponent8,values:[255,128,0,64,191,255])
        XCTAssertEqual(try ForegroundMaskPixels.erasure(source,width:3,height:2).values,[0,127,255,191,64,0])
    }
    func testInvalidOpacityDimensionsAndFormatsAreRejected() throws {
        for value: Float in [.nan,.infinity,-0.01,1.01] {
            let source = try buffer(kCVPixelFormatType_OneComponent32Float,values:[1,value,0,0,1,1])
            XCTAssertThrowsError(try ForegroundMaskPixels.erasure(source,width:3,height:2))
        }
        let color = try buffer(kCVPixelFormatType_32BGRA,values:[])
        XCTAssertThrowsError(try ForegroundMaskPixels.erasure(color,width:3,height:2))
        XCTAssertThrowsError(try ForegroundMaskPixels.erasure(color,width:Int.max,height:Int.max))
    }
    func testCancelledMaskReadRejectsWork() async throws {
        let source = try buffer(kCVPixelFormatType_OneComponent8,values:[255,128,0,64,191,255])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ForegroundMaskPixels.erasure(source,width:3,height:2)
        }
        do { _ = try await task.value; XCTFail("Cancelled mask read returned pixels") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try ForegroundMaskPixels.erasure(source,width:3,height:2).values,[0,127,255,191,64,0])
    }
}
