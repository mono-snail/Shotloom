import XCTest
@testable import DeskCapture

final class RepairBoundaryBlendTests: XCTestCase {
    private func image(width: Int = 64, height: Int = 48,
                       pixel: (Int, Int) -> [UInt8]) -> CGImage {
        var bytes = Data(count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let values = pixel(x, y)
            for c in 0..<4 { bytes[(y * width + x) * 4 + c] = values[c] }
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: CGDataProvider(data: bytes as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func mask() throws -> RepairRasterMask {
        try RepairSelection(strokes: [.init(points: [.init(x: 0.5, y: 0.5)], diameter: 28, erase: false)], feather: 0)
            .raster(width: 64, height: 48)
    }

    func testConstantColorMismatchIsRemovedWithoutChangingSourceOrOutsidePixels() throws {
        let base = image { _, _ in [24, 90, 170, 255] }
        let selected = try mask(), before = base.dataProvider!.data! as Data
        let repaired = image { x, y in selected.values[y * 64 + x] > 0 ? [84, 130, 200, 255] : [24, 90, 170, 255] }
        let result = try RepairBoundaryBlend.apply(base: base, repaired: repaired, mask: selected)
        XCTAssertEqual(result.dataProvider!.data! as Data, before)
        XCTAssertEqual(base.dataProvider!.data! as Data, before)
    }

    func testHiddenSourcePixelsAreNeverUsedAsColorBoundary() throws {
        let selected = try mask()
        let first = image { x, y in selected.values[y * 64 + x] > 0 ? [230, 0, 0, 255] : [100, 100, 100, 255] }
        let second = image { x, y in selected.values[y * 64 + x] > 0 ? [0, 0, 230, 255] : [100, 100, 100, 255] }
        let repaired = image { x, y in selected.values[y * 64 + x] > 0 ? [180, 180, 180, 255] : [100, 100, 100, 255] }
        let a = try RepairBoundaryBlend.apply(base: first, repaired: repaired, mask: selected)
        let b = try RepairBoundaryBlend.apply(base: second, repaired: repaired, mask: selected)
        XCTAssertEqual(a.dataProvider!.data! as Data, b.dataProvider!.data! as Data)
    }

    func testGradientAndTextureKeepOutsidePixelsWhileReducingColorOffset() throws {
        let selected = try mask()
        let base = image { x, y in let v = UInt8(40 + x + y); return [v, v, v, 255] }
        let repaired = image { x, y in
            let offset = selected.values[y * 64 + x] > 0 ? 60 + (x % 2 == 0 ? 6 : -6) : 0
            let value = UInt8(40 + x + y + offset)
            return [value, value, value, 255]
        }
        let result = try RepairBoundaryBlend.apply(base: base, repaired: repaired, mask: selected)
        let expected = base.dataProvider!.data! as Data, before = repaired.dataProvider!.data! as Data
        let after = result.dataProvider!.data! as Data
        var oldError = 0, newError = 0
        for p in 0..<(64 * 48) {
            if selected.values[p] == 0 {
                XCTAssertEqual(after[p * 4], before[p * 4])
                XCTAssertEqual(after[p * 4 + 3], before[p * 4 + 3])
            } else {
                oldError += abs(Int(before[p * 4]) - Int(expected[p * 4]))
                newError += abs(Int(after[p * 4]) - Int(expected[p * 4]))
            }
        }
        XCTAssertLessThan(newError, oldError / 3)
        let center = (24 * 64 + 32) * 4
        XCTAssertGreaterThan(abs(Int(after[center]) - Int(after[center + 4])), 5)
    }

    func testTransparencyFullSelectionAndOversizedROIRejectWithoutMutation() throws {
        let transparent = image { _, _ in [60, 60, 60, 128] }, selected = try mask()
        let before = transparent.dataProvider!.data! as Data
        XCTAssertThrowsError(try RepairBoundaryBlend.apply(base: transparent, repaired: transparent, mask: selected))
        XCTAssertEqual(transparent.dataProvider!.data! as Data, before)
        let opaque = image { _, _ in [60, 60, 60, 255] }
        let full = RepairRasterMask(width: 64, height: 48, values: Array(repeating: 255, count: 64 * 48))
        XCTAssertThrowsError(try RepairBoundaryBlend.apply(base: opaque, repaired: opaque, mask: full))
        let large = image(width: 600, height: 600) { _, _ in [60, 60, 60, 255] }
        let largeMask = RepairRasterMask(width: 600, height: 600, values: Array(repeating: 255, count: 600 * 600))
        XCTAssertThrowsError(try RepairBoundaryBlend.apply(base: large, repaired: large, mask: largeMask))
    }

    func testCancelledWorkCannotDeliverPixels() async throws {
        let base = image { _, _ in [60, 60, 60, 255] }, selected = try mask()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RepairBoundaryBlend.apply(base: base, repaired: base, mask: selected)
        }
        do { _ = try await task.value; XCTFail("Cancelled blending delivered pixels") }
        catch is CancellationError { }
    }
}
