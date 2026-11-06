import AppKit

/// Erase in the source pixel layout. Existing alpha, RGB, row padding and the
/// color profile outside the mask stay unchanged. Opaque skip lanes become alpha.
enum RepairTransparency {
    static func apply(base: CGImage, mask: RepairRasterMask) throws -> CGImage {
        try Task.checkCancellation()
        guard base.width > 0, base.height > 0, Double(base.width)*Double(base.height) <= 20_000_000,
              mask.width == base.width, mask.height == base.height, mask.values.count == base.width*base.height,
              base.bitsPerComponent == 8, base.bitsPerPixel == 32, base.colorSpace?.model == .rgb,
              base.decode == nil, !base.bitmapInfo.contains(.floatComponents),
              base.bytesPerRow >= base.width*4, Double(base.bytesPerRow)*Double(base.height) <= 100_000_000,
              let space = base.colorSpace, let source = base.dataProvider?.data else {
            throw CaptureError.message(L10n.text("此图片暂不支持精确透明蒙版，请先另存为8位RGB PNG。"))
        }
        let first: Bool, straight: Bool, addingAlpha: Bool
        let byteOrder = base.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        guard [UInt32(0), CGBitmapInfo.byteOrder32Little.rawValue, CGBitmapInfo.byteOrder32Big.rawValue].contains(byteOrder) else {
            throw CaptureError.message(L10n.text("图片字节顺序不支持精确透明蒙版。"))
        }
        let alpha: CGImageAlphaInfo
        switch base.alphaInfo {
        case .premultipliedFirst: first = true; straight = false; addingAlpha = false; alpha = .premultipliedFirst
        case .premultipliedLast: first = false; straight = false; addingAlpha = false; alpha = .premultipliedLast
        case .first: first = true; straight = true; addingAlpha = false; alpha = .first
        case .last: first = false; straight = true; addingAlpha = false; alpha = .last
        case .noneSkipFirst: first = true; straight = false; addingAlpha = true; alpha = .premultipliedFirst
        case .noneSkipLast: first = false; straight = false; addingAlpha = true; alpha = .premultipliedLast
        default: throw CaptureError.message(L10n.text("图片通道格式不支持精确透明蒙版。"))
        }
        let little = base.bitmapInfo.contains(.byteOrder32Little)
        let alphaIndex = first ? (little ? 3 : 0) : (little ? 0 : 3)
        let info = CGBitmapInfo(rawValue: (base.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | alpha.rawValue)
        var data = Data(source as Data)
        guard data.count >= base.bytesPerRow*base.height else { throw CaptureError.message(L10n.text("图片像素数据不完整。")) }
        try data.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self)
            for y in 0..<base.height {
                if y % 32 == 0 { try Task.checkCancellation() }
                for x in 0..<base.width {
                    let offset = y*base.bytesPerRow+x*4
                    if addingAlpha { output[offset+alphaIndex] = 255 }
                    let weight = Int(mask.values[y*base.width+x])
                    guard weight > 0 else { continue }
                    let retained = 255-weight
                    if straight {
                        let value = UInt8((Int(output[offset+alphaIndex])*retained+127)/255)
                        output[offset+alphaIndex] = value
                        if value == 0 { for c in 0..<4 where c != alphaIndex { output[offset+c] = 0 } }
                    } else {
                        for c in 0..<4 { output[offset+c] = UInt8((Int(output[offset+c])*retained+127)/255) }
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard let output = CGImage(width: base.width, height: base.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: base.bytesPerRow, space: space, bitmapInfo: info,
                                   provider: CGDataProvider(data: data as CFData)!, decode: nil,
                                   shouldInterpolate: base.shouldInterpolate, intent: base.renderingIntent) else {
            throw CaptureError.message(L10n.text("无法创建透明蒙版结果。"))
        }
        return output
    }
}
