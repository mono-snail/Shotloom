import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CaptureImageRead {
    static func decode(_ source: CGImageSource, decodeImmediately: Bool = false) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= 60_000, Double(width) * Double(height) <= 80_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, decodeImmediately ? [kCGImageSourceShouldCacheImmediately: true] as CFDictionary : nil) else { throw CaptureError.message(L10n.text("图片无效或超过容量上限。")) }
        return image
    }
    static func load(_ url: URL, maximumFileBytes: Int = 100_000_000, decodeImmediately: Bool = false) throws -> CGImage {
        guard maximumFileBytes > 0,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumFileBytes,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CaptureError.message(L10n.text("图片无法读取或超过文件容量上限。")) }
        return try decode(source, decodeImmediately: decodeImmediately)
    }
}

struct CaptureColorSample: Equatable {
    let red: Int
    let green: Int
    let blue: Int
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }
    var color: NSColor { NSColor(srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: 1) }
}

enum CapturePixelColor {
    static func hex(_ image: CGImage, at point: CGPoint) -> String? { sample(image, at: point)?.hex }
    static func sample(_ image: CGImage, at point: CGPoint) -> CaptureColorSample? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0, point.x < CGFloat(image.width), point.y < CGFloat(image.height),
              let pixel = image.cropping(to: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return true
        }
        guard rendered else { return nil }
        let alpha = max(1, Int(rgba[3]))
        return CaptureColorSample(red: min(255, Int(rgba[0]) * 255 / alpha),
                                  green: min(255, Int(rgba[1]) * 255 / alpha), blue: min(255, Int(rgba[2]) * 255 / alpha))
    }
}

enum CaptureImageTransform {
    static func render(_ image: CGImage, width: Int? = nil, height: Int? = nil,
                       turns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) throws -> CGImage {
        let rotation = ((turns % 4) + 4) % 4
        let rotatedSize = rotation % 2 == 0 ? CGSize(width: image.width, height: image.height)
            : CGSize(width: image.height, height: image.width)
        let size = CGSize(width: width ?? Int(rotatedSize.width), height: height ?? Int(rotatedSize.height))
        guard size.width > 0, size.height > 0, size.width * size.height <= 80_000_000,
              max(size.width, size.height) <= 60_000,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("输出尺寸无效或超过图片容量上限。"))
        }
        context.interpolationQuality = .high
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: (flipHorizontal ? -1 : 1) * size.width / rotatedSize.width,
                        y: (flipVertical ? -1 : 1) * size.height / rotatedSize.height)
        context.rotate(by: -CGFloat(rotation) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let result = context.makeImage() else { throw CaptureError.message(L10n.text("图片变换失败。")) }
        return result
    }
    static func combine(_ images: [CGImage], horizontal: Bool, gap: Int = 16) throws -> CGImage {
        guard !images.isEmpty, images.count <= 30 else { throw CaptureError.message(L10n.text("一次可拼接 1–30 张图片。")) }
        guard (0...100).contains(gap), images.allSatisfy({ $0.width <= 60_000 && $0.height <= 60_000 }) else { throw CaptureError.message(L10n.text("拼图尺寸或间距超过容量上限。")) }
        let width = horizontal ? images.reduce(0) { $0 + $1.width } + gap * (images.count - 1) : images.map(\.width).max()!
        let height = horizontal ? images.map(\.height).max()! : images.reduce(0) { $0 + $1.height } + gap * (images.count - 1)
        guard width > 0, height > 0, Double(width) * Double(height) <= 80_000_000, max(width, height) <= 60_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("拼图超过容量上限，请减少图片或先缩小尺寸。"))
        }
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var offset = 0
        for image in images {
            let rect = horizontal ? CGRect(x: offset, y: (height - image.height) / 2, width: image.width, height: image.height)
                : CGRect(x: (width - image.width) / 2, y: height - offset - image.height, width: image.width, height: image.height)
            context.draw(image, in: rect); offset += (horizontal ? image.width : image.height) + gap
        }
        return context.makeImage()!
    }
}

struct ImageTransformView: View {
    let source: CGImage
    let copy: (CGImage) -> Void
    let save: (CGImage) -> Void
    let close: () -> Void
    var cleanup: (CGImage) -> Void = { _ in }
    @State private var turns = 0
    @State private var flipHorizontal = false
    @State private var flipVertical = false
    @State private var width = 0
    @State private var height = 0
    @State private var linked = true
    @State private var ratio = 1.0
    @State private var horizontal = false
    @State private var gap = 16
    @State private var additions: [CGImage] = []
    @State private var rendered: CGImage?
    @State private var error: String?
    private var key: String { "\(turns):\(flipHorizontal):\(flipVertical):\(width):\(height):\(horizontal):\(gap):\(additions.count)" }
    var body: some View {
        StudioWorkspace(title: L10n.text("变换与拼图"), symbol: "rectangle.2.swap") {
            Button(L10n.text("裁剪与清理…")) { if let rendered { cleanup(rendered) } }.disabled(rendered == nil)
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark", action: close).keyboardShortcut(.cancelAction)
        } preview: {
            if let rendered { Image(decorative: rendered, scale: 1).resizable().scaledToFit() }
            else if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            else { ProgressView() }
        } inspector: {
            InspectorGroup(L10n.text("方向"), initiallyExpanded: true) {
                Button { turns = (turns + 1) % 4; let oldWidth = width; width = height; height = oldWidth; ratio = 1 / ratio } label: { Label(L10n.text("旋转 90°"), systemImage: "rotate.right") }
                Toggle(L10n.text("水平翻转"), isOn: $flipHorizontal)
                Toggle(L10n.text("垂直翻转"), isOn: $flipVertical)
            }
            InspectorGroup(L10n.text("尺寸"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("宽度（px）")) {
                    TextField(L10n.text("像素"), value: $width, format: .number)
                        .onChange(of: width) { _, value in if linked { height = Self.linkedHeight(width: value, ratio: ratio) } }
                }
                InspectorField(title: L10n.text("高度（px）")) {
                    TextField(L10n.text("像素"), value: $height, format: .number).disabled(linked)
                }
                Toggle(L10n.text("锁定比例"), isOn: $linked)
                Button(L10n.text("恢复原尺寸")) { turns = 0; width = source.width; height = source.height; ratio = Double(width) / Double(height) }
            }
            InspectorGroup(L10n.text("拼图")) {
                Button(L10n.text("添加图片…"), action: importImages)
                if !additions.isEmpty {
                    InspectorField(title: L10n.text("方向")) { Picker(L10n.text("方向"), selection: $horizontal) { Text(L10n.text("竖排")).tag(false); Text(L10n.text("横排")).tag(true) }.labelsHidden() }.pickerStyle(.segmented).labelsHidden()
                    Stepper(L10n.text("间距 \(gap) px"), value: $gap, in: 0...100, step: 4)
                    Button(L10n.text("清空拼图")) { additions = [] }
                }
            }
            if let error, rendered != nil {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } actions: {
            if let rendered { Text("\(rendered.width) × \(rendered.height) px").monospacedDigit().foregroundStyle(Palette.muted) }
            Spacer()
            Button(L10n.text("保存副本…")) { if let rendered { save(rendered) } }.disabled(rendered == nil)
            Button(L10n.text("复制图片")) { if let rendered { copy(rendered) } }.disabled(rendered == nil).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .onAppear { width = source.width; height = source.height; ratio = Double(width) / Double(height) }
            .task(id: key) {
                rendered = nil
                guard width > 0, height > 0 else { error = L10n.text("请输入有效的图片尺寸。"); return }
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let w = width, h = height, rotation = turns, fh = flipHorizontal, fv = flipVertical
                    let images = additions, isHorizontal = horizontal, spacing = gap
                    let image = try await Task.detached(priority: .userInitiated) {
                        let changed = try CaptureImageTransform.render(source, width: w, height: h, turns: rotation,
                                                                      flipHorizontal: fh, flipVertical: fv)
                        return images.isEmpty ? changed : try CaptureImageTransform.combine([changed] + images, horizontal: isHorizontal, gap: spacing)
                    }.value
                    try Task.checkCancellation(); rendered = image; error = nil
                } catch is CancellationError { }
                catch { rendered = nil; self.error = error.localizedDescription }
            }
    }
    static func linkedHeight(width: Int, ratio: Double) -> Int {
        guard (1...60_000).contains(width), ratio.isFinite, ratio > 0 else { return 0 }
        let value = (Double(width) / ratio).rounded()
        guard value.isFinite, value <= 60_000 else { return 0 }
        return max(1, Int(value))
    }
    private func importImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let files = panel.urls
            Task {
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        try files.map { url -> CGImage in
                            try CaptureImageRead.load(url)
                        }
                    }.value
                    guard loaded.count + additions.count < 30 else { throw CaptureError.message(L10n.text("一次最多拼接 30 张图片。")) }
                    additions.append(contentsOf: loaded)
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
