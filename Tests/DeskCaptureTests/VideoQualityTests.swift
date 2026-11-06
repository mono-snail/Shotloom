import XCTest
import CoreImage
import Metal
@testable import DeskCapture

final class VideoQualityTests: XCTestCase {
    private func context() throws -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable; quality render coverage unavailable") }
        guard device.supportsDynamicLibraries else { throw XCTSkip("Device lacks Metal dynamic libraries required by quality kernel; no rendered quality claim") }
        return CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    }
    private func fixture(width: Int = 96, height: Int = 32, pixel: (Int, Int) -> [Float]) -> CIImage {
        var values: [Float] = []
        for y in 0..<height { for x in 0..<width { values.append(contentsOf: pixel(x, y)) } }
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }
    private func pixels(_ image: CIImage, bounds: CGRect, context: CIContext) -> [Float] {
        var values = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        context.render(image, toBitmap: &values, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        return values
    }
    func testBypassPreservesEveryPixelAndZeroStrengthDisablesKernel() throws {
        let context = try context(), image = fixture { x, y in let a = Float(y % 4 + 1) / 4; return [Float(x) / 96 * a, 0.2 * a, 0.3 * a, a] }
        let bypass = try VideoQualityFilter(options: .init())
        XCTAssertEqual(pixels(try bypass.apply(image), bounds: image.extent, context: context), pixels(image, bounds: image.extent, context: context))
        var zero = VideoQualityOptions(); zero.deband = true; zero.strength = 0
        XCTAssertFalse(zero.active)
    }
    func testStrongTextEdgesHaveNoOvershootAndAlphaIsPreserved() throws {
        let context = try context(), image = fixture { x, y in let a: Float = y < 16 ? 0.5 : 1; let value: Float = x % 8 < 4 ? 0 : a; return [value, value, value, a] }
        var options = VideoQualityOptions(); options.deband = true; options.strength = 1; options.dither = 0; options.sharpen = true; options.detail = 0.75
        let output = pixels(try VideoQualityFilter(options: options).apply(image), bounds: image.extent, context: context)
        let original = pixels(image, bounds: image.extent, context: context)
        for i in stride(from: 0, to: output.count, by: 4) {
            XCTAssertEqual(output[i + 3], original[i + 3], accuracy: 0.00001)
            for channel in 0..<3 { XCTAssertEqual(output[i + channel], original[i + channel], accuracy: 0.0002) }
        }
    }
    func testGradientBoundarySmoothingAndTileConsistency() throws {
        let context = try context(), image = fixture { x, _ in let value = Float(x / 8) * 0.008 + 0.2; return [value, value, value, 1] }
        var options = VideoQualityOptions(); options.deband = true; options.strength = 1; options.dither = 0
        let filter = try VideoQualityFilter(options: options), output = try filter.apply(image)
        let full = pixels(output, bounds: image.extent, context: context), original = pixels(image, bounds: image.extent, context: context)
        let a = (16 * 96 + 7) * 4, b = a + 4
        XCTAssertLessThan(full[b] - full[a], original[b] - original[a])
        let left = pixels(output, bounds: CGRect(x: 0, y: 0, width: 48, height: 32), context: context)
        let right = pixels(output, bounds: CGRect(x: 48, y: 0, width: 48, height: 32), context: context)
        for y in 0..<32 { for x in 0..<96 { for c in 0..<4 {
            let tile = x < 48 ? left[(y * 48 + x) * 4 + c] : right[(y * 48 + x - 48) * 4 + c]
            XCTAssertEqual(tile, full[(y * 96 + x) * 4 + c], accuracy: 0.00002)
        } } }
        options.dither = 0.3
        let dithered = try VideoQualityFilter(options: options)
        let first = pixels(try dithered.apply(image), bounds: image.extent, context: context)
        XCTAssertEqual(first, pixels(try dithered.apply(image), bounds: image.extent, context: context))
    }
    func testBudgetHDRAndSettingsCompatibility() throws {
        var options = VideoQualityOptions(); options.deband = true
        let size = CGSize(width: 3840, height: 2160)
        XCTAssertLessThanOrEqual(try options.estimatedMiB(source: size, output: size, opticalSamples: 7), 1024)
        options.memoryMiB = 256
        XCTAssertThrowsError(try options.estimatedMiB(source: size, output: size, opticalSamples: 7))
        XCTAssertThrowsError(try options.estimatedMiB(source: CGSize(width: Double.infinity, height: 1), output: size, opticalSamples: 0))
        XCTAssertTrue(VideoQualityFilter.isHDR(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String))
        XCTAssertFalse(VideoQualityFilter.isHDR(nil))
        var effects = RecordingEffectsOptions(); effects.quality = .init()
        XCTAssertEqual(try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects)).quality, effects.quality)
        effects.quality = nil
        XCTAssertNil(try JSONDecoder().decode(RecordingEffectsOptions.self, from: JSONEncoder().encode(effects)).quality)
    }
}
