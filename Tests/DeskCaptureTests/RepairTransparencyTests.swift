import XCTest
import AppKit
@testable import DeskCapture

final class RepairTransparencyTests: XCTestCase {
    private func fixture(_ alpha: CGImageAlphaInfo, little: Bool = false) throws -> (CGImage, Int) {
        let first = [.first,.premultipliedFirst,.noneSkipFirst].contains(alpha)
        let alphaIndex = first ? (little ? 3 : 0) : (little ? 0 : 3)
        let premultiplied = [.premultipliedFirst,.premultipliedLast].contains(alpha)
        let opaque = [.noneSkipFirst,.noneSkipLast].contains(alpha)
        var bytes = [UInt8](repeating: 0xCD,count: 24*3)
        for y in 0..<3 { for x in 0..<4 {
            let channels = (0..<4).filter { $0 != alphaIndex }
            for (i,c) in channels.enumerated() { bytes[y*24+x*4+c] = UInt8((premultiplied ? [57,39,11] : [211,133,77])[i]+x+y) }
            bytes[y*24+x*4+alphaIndex] = opaque ? 0x2D : UInt8(123+x+y)
        } }
        let image = try XCTUnwrap(CGImage(width: 4,height: 3,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 24,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | (little ? CGBitmapInfo.byteOrder32Little.rawValue : CGBitmapInfo.byteOrder32Big.rawValue)),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .relativeColorimetric))
        return (image,alphaIndex)
    }
    private var weights: [UInt8] { [0,0,0,0, 0,128,255,64, 0,0,0,0] }
    private var mask: RepairRasterMask { .init(width: 4,height: 3,values: weights) }

    func testAlphaLayoutsKeepUnselectedBytesPaddingAndProfile() throws {
        for alpha: CGImageAlphaInfo in [.first,.last,.premultipliedFirst,.premultipliedLast] {
            for little in [false,true] {
                let (base,alphaIndex) = try fixture(alpha,little: little)
                let before = base.dataProvider!.data! as Data
                let output = try RepairTransparency.apply(base: base,mask: mask)
                let after = output.dataProvider!.data! as Data
                XCTAssertEqual(output.bitmapInfo,base.bitmapInfo)
                XCTAssertEqual(output.bytesPerRow,base.bytesPerRow)
                XCTAssertEqual(output.colorSpace?.name,base.colorSpace?.name)
                XCTAssertEqual(output.renderingIntent,base.renderingIntent)
                for y in 0..<3 { for x in 0..<4 where weights[y*4+x] == 0 {
                    let start = y*24+x*4
                    XCTAssertEqual(after[start..<start+4],before[start..<start+4])
                } }
                for y in 0..<3 { XCTAssertEqual(after[y*24+16..<y*24+24],before[y*24+16..<y*24+24]) }
                XCTAssertEqual(Array(after[32..<36]),[0,0,0,0])
                XCTAssertLessThan(after[28+alphaIndex],before[28+alphaIndex])
                XCTAssertEqual(base.dataProvider!.data! as Data,before)
            }
        }
    }

    func testOpaqueSkipLanesBecomeAlphaWithoutChangingOtherUnselectedChannels() throws {
        for alpha: CGImageAlphaInfo in [.noneSkipFirst,.noneSkipLast] {
            for little in [false,true] {
                let (base,alphaIndex) = try fixture(alpha,little: little)
                let before = base.dataProvider!.data! as Data
                let output = try RepairTransparency.apply(base: base,mask: mask)
                let after = output.dataProvider!.data! as Data
                XCTAssertEqual(output.alphaInfo,alpha == .noneSkipFirst ? .premultipliedFirst : .premultipliedLast)
                for y in 0..<3 { for x in 0..<4 where weights[y*4+x] == 0 {
                    let start = y*24+x*4
                    XCTAssertEqual(after[start+alphaIndex],255)
                    for c in 0..<4 where c != alphaIndex { XCTAssertEqual(after[start+c],before[start+c]) }
                } }
                for y in 0..<3 { XCTAssertEqual(after[y*24+16..<y*24+24],before[y*24+16..<y*24+24]) }
                XCTAssertEqual(Array(after[32..<36]),[0,0,0,0])
                XCTAssertEqual(base.dataProvider!.data! as Data,before)
            }
        }
    }

    func testFeatheredStraightAlphaKeepsRGBAndPremultipliedAlphaScalesRGB() throws {
        for alpha: CGImageAlphaInfo in [.last,.premultipliedLast] {
            let (base,a) = try fixture(alpha)
            let before = base.dataProvider!.data! as Data
            let after = try RepairTransparency.apply(base: base,mask: mask).dataProvider!.data! as Data
            let index = 28, retained = 127
            XCTAssertEqual(after[index+a],UInt8((Int(before[index+a])*retained+127)/255))
            for c in 0..<4 where c != a {
                let expected = alpha == .last ? before[index+c] : UInt8((Int(before[index+c])*retained+127)/255)
                XCTAssertEqual(after[index+c],expected)
            }
        }
    }

    func testErasingClearsHiddenRGBWhileUntouchedTransparentPixelsStayUnchanged() throws {
        let (fixture,a) = try fixture(.last)
        var bytes = fixture.dataProvider!.data! as Data
        bytes[28+a] = 0; bytes[a] = 0
        let base = try XCTUnwrap(CGImage(width: 4,height: 3,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 24,
            space: fixture.colorSpace!,bitmapInfo: fixture.bitmapInfo,provider: CGDataProvider(data: bytes as CFData)!,
            decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let after = try RepairTransparency.apply(base: base,mask: mask).dataProvider!.data! as Data
        XCTAssertEqual(Array(after[28..<32]),[0,0,0,0])
        XCTAssertEqual(after[0..<4],bytes[0..<4])
    }

    func testActualTransparentRepairKeepsOutsideAndOriginalImage() async throws {
        let (base,_) = try fixture(.last)
        let before = base.dataProvider!.data! as Data
        for diameter: CGFloat in [1,2] {
            let selection = RepairSelection(strokes: [.init(points: [.init(x: 0.625,y: 0.5)],diameter: diameter,erase: false)],feather: 0)
            let output = try await LocalImageRepair.render(base: base,original: base,selection: selection,method: .transparent,anchor: nil,modelID: nil)
            let after = output.dataProvider!.data! as Data
            XCTAssertEqual(Array(after[32..<36]),[0,0,0,0])
            for offset in 0..<before.count where !(32..<36).contains(offset) { XCTAssertEqual(after[offset],before[offset]) }
        }
        XCTAssertEqual(base.dataProvider!.data! as Data,before)
    }

    func testInvalidMaskAndNonRGBFormatsAreRejected() throws {
        let (base,_) = try fixture(.last)
        XCTAssertThrowsError(try RepairTransparency.apply(base: base,mask: .init(width: 4,height: 3,values: [0])))
        XCTAssertThrowsError(try RepairTransparency.apply(base: base,mask: .init(width: Int.max,height: Int.max,values: [])))
        let gray = try XCTUnwrap(CGImage(width: 4,height: 3,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],provider: CGDataProvider(data: Data(repeating: 127,count: 12) as CFData)!,
            decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        XCTAssertThrowsError(try RepairTransparency.apply(base: gray,mask: mask))
    }

    func testCancelledTransparentRepairDoesNotReturnOutput() async throws {
        let (base,_) = try fixture(.last)
        let selection = RepairSelection(strokes: [.init(points: [.init(x: 0.5,y: 0.5)],diameter: 2,erase: false)],feather: 0)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalImageRepair.render(base: base,original: base,selection: selection,method: .transparent,anchor: nil,modelID: nil)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled repair must not return pixels")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
