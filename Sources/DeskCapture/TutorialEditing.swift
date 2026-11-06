import Foundation
import ImageIO
import CoreGraphics

struct TutorialFrame: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var detail: String
    var file: String
    var clickX: Double
    var clickY: Double
}
enum TutorialEditing {
    static func approximateBytes(_ steps: [TutorialStep]) -> Int { steps.reduce(0) { $0 + $1.title.utf8.count + $1.detail.utf8.count + frames($1).reduce(0) { $0 + $1.title.utf8.count + $1.detail.utf8.count + 256 } } }
    static func frames(_ step: TutorialStep) -> [TutorialFrame] {
        step.parts ?? [.init(id: step.id, title: step.title, detail: step.detail, file: step.file, clickX: step.clickX, clickY: step.clickY)]
    }
    static func validate(_ steps: [TutorialStep], allowEmpty: Bool = false) throws {
        let all = steps.flatMap(frames)
        guard (!steps.isEmpty || allowEmpty), steps.count <= 100, Set(steps.map(\.id)).count == steps.count, all.count <= 100,
              steps.allSatisfy({ PortableProject.safe($0.file) && $0.file.hasSuffix(".png") && $0.clickX.isFinite && $0.clickY.isFinite && (0...1).contains($0.clickX) && (0...1).contains($0.clickY) && ($0.parts == nil || $0.parts?.first?.file == $0.file) && $0.title.utf8.count <= 1024 && $0.detail.utf8.count <= 64_000 && ($0.timestamp?.isFinite != false) && ($0.windowKey?.utf8.count ?? 0) <= 512 && $0.parts?.isEmpty != true }),
              all.allSatisfy({ PortableProject.safe($0.file) && $0.file.hasSuffix(".png") && $0.title.utf8.count <= 2048 && $0.detail.utf8.count <= 128_000 && $0.clickX.isFinite && $0.clickY.isFinite && (0...1).contains($0.clickX) && (0...1).contains($0.clickY) }) else { throw CaptureError.message(L10n.text("教程步骤/图片路径/点击坐标或数量无效。")) }
        guard try JSONEncoder().encode(steps).count <= 2_000_000 else { throw CaptureError.message(L10n.text("教程文本超过2MB。")) }
    }
    static func validateImage(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32_000_000,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source).map({ $0 as String }) == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 32_000_000 else { throw CaptureError.message(L10n.text("教程图片缺失、损坏或超预算：\(url.lastPathComponent)")) }
    }
    static func firstNearby(_ steps: [TutorialStep], directory: URL) throws -> Int? {
        try validate(steps)
        for i in steps.indices.dropLast() {
            try Task.checkCancellation()
            let a = steps[i], b = steps[i + 1]
            guard let timeA = a.timestamp, let timeB = b.timestamp, timeB >= timeA, timeB - timeA <= 1.2,
                  let key = a.windowKey, key == b.windowKey, let last = frames(a).last, let first = frames(b).first,
                  hypot(last.clickX - first.clickX, last.clickY - first.clickY) <= 0.06 else { continue }
            if try similarity(directory.appendingPathComponent(last.file), directory.appendingPathComponent(first.file)) <= 0.04 { return i }
        }
        return nil
    }
    private static func similarity(_ a: URL, _ b: URL) throws -> Double {
        func sample(_ url: URL) throws -> [UInt8] {
            try validateImage(url)
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary),
                  let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message(L10n.text("无法比较教程图片。")) }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 64 * 64 * 4))
        }
        let x = try sample(a), y = try sample(b)
        return zip(x, y).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / (64 * 64 * 3 * 255)
    }
    static func merge(_ steps: [TutorialStep], at index: Int) throws -> [TutorialStep] {
        guard steps.indices.contains(index), steps.indices.contains(index + 1) else { throw CaptureError.message(L10n.text("合并步骤不存在。")) }
        func flatten(_ step: TutorialStep) -> [TutorialFrame] {
            var result = frames(step)
            if step.parts != nil, !result.isEmpty {
                if result[0].title != step.title { result[0].title = step.title + L10n.text(" · ") + result[0].title }
                if !step.detail.isEmpty { result[0].detail = step.detail + "\n" + result[0].detail }
            }
            return result
        }
        var result = steps, combined = steps[index]
        combined.parts = flatten(steps[index]) + flatten(steps[index + 1]); combined.detail = ""
        combined.timestamp = steps[index + 1].timestamp
        result[index] = combined; result.remove(at: index + 1); try validate(result); return result
    }
    static func split(_ steps: [TutorialStep], id: UUID) throws -> [TutorialStep] {
        guard let index = steps.firstIndex(where: { $0.id == id }), let parts = steps[index].parts else { return steps }
        let group = steps[index]
        var replacements = parts.map { TutorialStep(title: $0.title, detail: $0.detail, file: $0.file, clickX: $0.clickX, clickY: $0.clickY) }
        if !replacements.isEmpty {
            if group.title != replacements[0].title { replacements[0].title = group.title + L10n.text(" · ") + replacements[0].title }
            if !group.detail.isEmpty { replacements[0].detail = group.detail + "\n" + replacements[0].detail }
        }
        var result = steps; result.replaceSubrange(index...index, with: replacements); try validate(result); return result
    }
}
