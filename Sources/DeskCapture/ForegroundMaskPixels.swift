import CoreVideo
import Foundation

/// Vision's scaled membership mask, converted to top-left erase weights without
/// passing the source RGB/alpha through an image renderer.
enum ForegroundMaskPixels {
    static func erasure(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> RepairRasterMask {
        try Task.checkCancellation()
        guard width > 0, height > 0, Double(width)*Double(height) <= 20_000_000,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              !CVPixelBufferIsPlanar(buffer) else { throw CaptureError.message(L10n.text("主体蒙版尺寸或平面格式不受支持。")) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            throw CaptureError.message(L10n.text("主体蒙版像素格式不受支持，请保留原图并手动精修。"))
        }
        let componentBytes = format == kCVPixelFormatType_OneComponent32Float ? 4 : 1
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard stride >= width*componentBytes, stride % componentBytes == 0, Double(stride)*Double(height) <= 100_000_000,
              CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else {
            throw CaptureError.message(L10n.text("无法读取主体蒙版。"))
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetDataSize(buffer) >= stride*height else {
            throw CaptureError.message(L10n.text("主体蒙版数据不完整。"))
        }
        var weights = [UInt8](repeating: 0,count: width*height)
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let row = source.advanced(by: y*stride)
            for x in 0..<width {
                let keep: UInt8
                if componentBytes == 4 {
                    let value = row.assumingMemoryBound(to: Float.self)[x]
                    guard value.isFinite, (0...1).contains(value) else { throw CaptureError.message(L10n.text("主体蒙版包含无效透明度，请重新识别。")) }
                    keep = UInt8((Double(value)*255).rounded())
                } else { keep = row.assumingMemoryBound(to: UInt8.self)[x] }
                weights[y*width+x] = 255-keep
            }
        }
        return .init(width: width,height: height,values: weights)
    }
}
