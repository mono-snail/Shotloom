import AppKit

struct ScrollFrameStability {
    let stable: Bool
    let regions: [CGRect] // Normalized top-left block bounds, no UI state.
    var thumbnail: CGImage? = nil
    /// Manual scrolling is intentional motion. Validate the translated overlap
    /// in color as well as the textured seam; unrelated animation still waits.
    static func compareManual(_ previous: CGImage, _ next: CGImage, axis: ScrollAxis,
                              direction: ScrollDirection) -> ScrollFrameStability {
        let stationary = compare(previous, next)
        guard !stationary.stable,
              let match = ScrollMatcher.match(previous: previous, next: next, axis: axis, direction: direction),
              match.offset > 0, match.error < 3 else { return stationary }
        let before = direction == .forward ? previous : next
        let after = direction == .forward ? next : previous
        let edges = ScrollFixedEdgeDetector.detect(previous: before, next: after, axis: axis, offset: match.offset)
        let length = (axis == .vertical ? before.height : before.width) - edges.leading - edges.trailing - match.offset
        guard length >= 40 else { return stationary }
        let oldRect = axis == .vertical
            ? CGRect(x: 0, y: edges.leading + match.offset, width: before.width, height: length)
            : CGRect(x: edges.leading + match.offset, y: 0, width: length, height: before.height)
        let newRect = axis == .vertical
            ? CGRect(x: 0, y: edges.leading, width: after.width, height: length)
            : CGRect(x: edges.leading, y: 0, width: length, height: after.height)
        guard let oldBody = before.cropping(to: oldRect), let newBody = after.cropping(to: newRect),
              compare(oldBody, newBody).stable else { return stationary }
        return ScrollFrameStability(stable: true, regions: [])
    }
    static func compare(_ previous: CGImage, _ next: CGImage) -> ScrollFrameStability {
        guard previous.width == next.width, previous.height == next.height else {
            return ScrollFrameStability(stable: false, regions: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            bytes.withUnsafeMutableBytes { memory in
                let context = CGContext(data: memory.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            return bytes
        }
        let a = pixels(previous), b = pixels(next)
        var regions: [CGRect] = []
        for row in 0..<8 {
            for column in 0..<8 {
                var error = 0
                for y in row * 8..<(row + 1) * 8 {
                    for x in column * 8..<(column + 1) * 8 {
                        for channel in 0..<4 { error += abs(Int(a[(y * 64 + x) * 4 + channel]) - Int(b[(y * 64 + x) * 4 + channel])) }
                    }
                }
                if Double(error) / (64 * 3) > 1.5 {
                    regions.append(CGRect(x: Double(column) / 8, y: Double(row) / 8, width: 0.125, height: 0.125))
                }
            }
        }
        // A small local animation can be tolerated by the separately validated
        // seam matcher. Broad motion/loading never reaches the disk stitcher.
        guard !regions.isEmpty else { return ScrollFrameStability(stable: true, regions: []) }
        let scale = min(220.0 / Double(next.width), 140.0 / Double(next.height))
        let width = max(1, Int(Double(next.width) * scale)), height = max(1, Int(Double(next.height) * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(next, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ScrollFrameStability(stable: regions.count <= 6, regions: regions, thumbnail: context?.makeImage())
    }
}

/// Shared by manual and automatic capture. Never commits broad motion, and
/// bounds retries without discarding accepted segments. Times are monotonic.
struct ScrollStabilityGate {
    enum Decision: Equatable { case accept, wait, pause }
    private var unstableSince: TimeInterval?
    mutating func evaluate(stable: Bool, now: TimeInterval) -> Decision {
        if stable { unstableSince = nil; return .accept }
        if unstableSince == nil { unstableSince = now }
        return now - (unstableSince ?? now) >= 8 ? .pause : .wait
    }
}

struct ScrollResponseGate {
    enum Decision: Equatable { case accept, wait, acceptAndPause }
    private var expectedPixels = 0
    private var partialOffsets: [Int] = []
    mutating func didScroll(expectedPixels: Int) {
        self.expectedPixels = max(1, expectedPixels); partialOffsets.removeAll(keepingCapacity: true)
    }
    mutating func evaluate(offset: Int?) -> Decision {
        guard expectedPixels > 0 else { return .accept }
        guard let offset, offset > 0 else {
            partialOffsets.removeAll(keepingCapacity: true)
            return .accept
        }
        if offset >= expectedPixels - 1 {
            expectedPixels = 0; partialOffsets.removeAll(keepingCapacity: true); return .accept
        }
        partialOffsets.append(offset)
        if partialOffsets.count > 3 { partialOffsets.removeFirst() }
        // Fractional scrolling and raster rounding can alternate neighboring
        // offsets forever. Require a tight three-sample range rather than exact
        // equality, without treating steadily accumulating motion as settled.
        // This releases only the response wait; append still validates the seam
        // at the actual offset and preserves the existing slow-next-step path.
        if partialOffsets.count == 3,
           let lower = partialOffsets.min(), let upper = partialOffsets.max(), upper - lower <= 2 {
            expectedPixels = 0; partialOffsets.removeAll(keepingCapacity: true)
            return .acceptAndPause
        }
        return .wait
    }
}

import SwiftUI

struct ScrollDynamicRegionsView: View {
    let image: CGImage?
    let regions: [CGRect]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("当前位置的变化区域")).font(.headline)
            Text(L10n.text("检测到 \(regions.count) 个粗略区域")).font(.caption.monospacedDigit())
            if let image {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                    let x = (geometry.size.width - width) / 2, y = (geometry.size.height - height) / 2
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().frame(width: width, height: height).offset(x: x, y: y)
                        ForEach(Array(regions.enumerated()), id: \.offset) { _, rect in
                            Rectangle().stroke(Color.orange, lineWidth: 1.5)
                                .frame(width: rect.width * width, height: rect.height * height)
                                .offset(x: x + rect.minX * width, y: y + rect.minY * height)
                        }
                    }
                }.frame(width: 240, height: 150).accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("动态位置预览，\(regions.count) 个粗略区域"))
            }
        }.padding(16).frame(width: 280)
    }
}
