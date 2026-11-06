import AppKit

/// The automatic subject mask is replaceable. Manual edits made after it are
/// retained as exact pixel overrides, including their already-rendered feather.
struct RepairSubjectComposition: Sendable {
    let base: CGImage
    private(set) var overrides: RepairRasterMask?
    private(set) var overrideImage: CGImage?
    init(base: CGImage) { self.base = base }

    func addingOverride(image: CGImage, mask: RepairRasterMask) throws -> Self {
        try Task.checkCancellation()
        guard image.width == base.width, image.height == base.height, mask.width == base.width, mask.height == base.height,
              Double(base.width)*Double(base.height) <= 20_000_000, mask.values.count == base.width*base.height else {
            throw CaptureError.message(L10n.text("手工精修与主体蒙版尺寸不一致。"))
        }
        var result = self
        var values = overrides?.values ?? [UInt8](repeating: 0,count: mask.values.count)
        for y in 0..<mask.height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<mask.width where mask.values[y*mask.width+x] > 0 { values[y*mask.width+x] = 255 }
        }
        result.overrides = .init(width: mask.width,height: mask.height,values: values)
        result.overrideImage = image
        return result
    }

    func applying(_ erasure: RepairRasterMask) throws -> CGImage {
        let filtered = try RepairTransparency.apply(base: base,mask: erasure)
        guard let overrides, let overrideImage else { return filtered }
        guard filtered.width == overrideImage.width, filtered.height == overrideImage.height,
              filtered.bitsPerComponent == 8, filtered.bitsPerPixel == 32,
              overrideImage.bitsPerComponent == 8, overrideImage.bitsPerPixel == 32, overrideImage.decode == nil,
              overrideImage.bytesPerRow >= overrideImage.width*4,
              filtered.bitmapInfo == overrideImage.bitmapInfo,
              let space = filtered.colorSpace, let editedSpace = overrideImage.colorSpace, CFEqual(space,editedSpace),
              let source = filtered.dataProvider?.data, let edited = overrideImage.dataProvider?.data,
              overrides.values.count == filtered.width*filtered.height,
              Double(overrideImage.bytesPerRow)*Double(overrideImage.height) <= 100_000_000 else {
            throw CaptureError.message(L10n.text("精修像素格式与主体结果不一致，已保留当前结果。"))
        }
        var data = Data(source as Data)
        let editedData = edited as Data
        guard data.count >= filtered.bytesPerRow*filtered.height, editedData.count >= overrideImage.bytesPerRow*overrideImage.height else {
            throw CaptureError.message(L10n.text("精修像素数据不完整。"))
        }
        try data.withUnsafeMutableBytes { output in
            try editedData.withUnsafeBytes { input in
                let dst = output.bindMemory(to: UInt8.self), src = input.bindMemory(to: UInt8.self)
                for y in 0..<filtered.height {
                    if y % 32 == 0 { try Task.checkCancellation() }
                    for x in 0..<filtered.width where overrides.values[y*filtered.width+x] > 0 {
                        let d = y*filtered.bytesPerRow+x*4, s = y*overrideImage.bytesPerRow+x*4
                        for channel in 0..<4 { dst[d+channel] = src[s+channel] }
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard let result = CGImage(width: filtered.width,height: filtered.height,bitsPerComponent: 8,bitsPerPixel: 32,
            bytesPerRow: filtered.bytesPerRow,space: space,bitmapInfo: filtered.bitmapInfo,
            provider: CGDataProvider(data: data as CFData)!,decode: nil,shouldInterpolate: filtered.shouldInterpolate,intent: filtered.renderingIntent) else {
            throw CaptureError.message(L10n.text("无法合成主体精修结果。"))
        }
        return result
    }

    var retainedImages: [CGImage] { [base] + (overrideImage.map { [$0] } ?? []) }
}
