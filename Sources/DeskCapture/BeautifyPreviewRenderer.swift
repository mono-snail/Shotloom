import AppKit

/// Native rendering can finish its current draw, but cancelled queued requests
/// must not allocate another full-size canvas. One worker belongs to each view.
actor BeautifyPreviewRenderer {
    static let previewMaximumDimension = 1600

    func render(_ source: CGImage, style: BeautifyStyle, layout: BeautifyLayout,
                padding: Double, roundness: Double, background: CGImage?, fullResolution: Bool = false, watermark: ImageWatermark = .init()) throws -> CGImage {
        try Task.checkCancellation()
        let result = try CaptureBeautifier.render(source, style: style, paddingPercent: padding,
                                                 roundness: roundness, layout: layout, customBackground: background,
                                                 maximumDimension: fullResolution ? nil : Self.previewMaximumDimension, watermark: watermark)
        try Task.checkCancellation()
        return result
    }
}
