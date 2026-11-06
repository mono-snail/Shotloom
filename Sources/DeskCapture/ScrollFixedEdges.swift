import AppKit

struct ScrollFixedEdges: Equatable, Sendable {
    var leading = 0
    var trailing = 0
    static let none = ScrollFixedEdges()
    var isEmpty: Bool { leading == 0 && trailing == 0 }
    func valid(length: Int) -> Bool { isEmpty ? length > 0 : leading >= 0 && trailing >= 0 && leading + trailing < length - 20 }
    func bodyRect(_ image: CGImage, axis: ScrollAxis) -> CGRect {
        axis == .vertical ? CGRect(x: 0, y: leading, width: image.width, height: image.height - leading - trailing)
            : CGRect(x: leading, y: 0, width: image.width - leading - trailing, height: image.height)
    }
}

enum ScrollFixedEdgeDetector {
    /// Identical headers alone can also be repeated headlines in the document.
    /// Automatic treatment requires that the proposed bar cannot be explained
    /// by the independently matched movement of the body.
    static func supportsAutomaticResolution(previous: CGImage, next: CGImage, edges: ScrollFixedEdges,
                                            axis: ScrollAxis, direction: ScrollDirection, offset: Int) throws -> Bool {
        guard !edges.isEmpty, offset > 0 else { return false }
        let prior = direction == .forward ? previous : next
        let current = direction == .forward ? next : previous
        let length = axis == .vertical ? prior.height : prior.width
        for (start, count, leading) in [(0, edges.leading, true), (length - edges.trailing, edges.trailing, false)] where count > 0 {
            try Task.checkCancellation()
            let priorStart = leading ? offset : start
            let currentStart = leading ? 0 : start - offset
            guard priorStart >= 0, currentStart >= 0, priorStart + count <= length, currentStart + count <= length else { return false }
            func strip(_ image: CGImage, start: Int) -> CGImage? {
                image.cropping(to: axis == .vertical ? CGRect(x: 0, y: start, width: image.width, height: count)
                    : CGRect(x: start, y: 0, width: count, height: image.height))
            }
            guard let a = strip(prior, start: priorStart), let b = strip(current, start: currentStart) else { return false }
            // If it is also a valid moving piece, this pair is ambiguous. Keep
            // the original frame and ask rather than silently removing text.
            if try similar(a, b) { return false }
        }
        return true
    }

    /// Match the start/end of the body overlap too. A taller header could
    /// otherwise masquerade as a slightly smaller scroll offset because the
    /// general matcher deliberately ignores margins and local animations.
    static func bodyBoundariesAgree(previous: CGImage, next: CGImage, edges: ScrollFixedEdges,
                                    axis: ScrollAxis, direction: ScrollDirection, offset: Int) throws -> Bool {
        guard let previousBody = previous.cropping(to: edges.bodyRect(previous, axis: axis)),
              let nextBody = next.cropping(to: edges.bodyRect(next, axis: axis)) else { return false }
        let prior = direction == .forward ? previousBody : nextBody
        let current = direction == .forward ? nextBody : previousBody
        let length = axis == .vertical ? prior.height : prior.width
        let overlap = length - offset, band = min(12, overlap)
        guard offset > 0, band > 0 else { return false }
        for start in [0, max(0, overlap - band)] {
            func crop(_ image: CGImage, at position: Int) -> CGImage? {
                image.cropping(to: axis == .vertical ? CGRect(x: 0, y: position, width: image.width, height: band)
                    : CGRect(x: position, y: 0, width: band, height: image.height))
            }
            guard let a = crop(prior, at: start + offset), let b = crop(current, at: start),
                  try boundaryAgrees(a, b, axis: axis) else { return false }
        }
        return true
    }

    /// A playing thumbnail may intersect either boundary while the page still
    /// translates correctly. A bounded cross-axis outlier must not veto all of
    /// the independently matched text. Keep both physical boundaries mandatory:
    /// searching farther into the overlap would hide a growing/collapsing bar.
    private static func boundaryAgrees(_ a: CGImage, _ b: CGImage, axis: ScrollAxis) throws -> Bool {
        if try similar(a, b) { return true }
        let cross = min(384, axis == .vertical ? a.width : a.height)
        let depth = axis == .vertical ? a.height : a.width
        let lanes = 12
        guard cross >= lanes * 4, depth >= 4 else { return false }
        let width = axis == .vertical ? cross : depth
        let height = axis == .vertical ? depth : cross
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
                guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw CaptureError.message(L10n.text("无法核对长图衔接位置，已截内容保留。")) }
            return bytes
        }
        let first = try pixels(a), second = try pixels(b)
        var rejected: [Int] = []
        var textured = 0, agreeingTextured = 0
        for lane in 0..<lanes {
            try Task.checkCancellation()
            var error = 0, changed = 0, samples = 0
            var low = 255, high = 0
            for along in 0..<depth {
                for across in (lane * cross / lanes)..<((lane + 1) * cross / lanes) {
                    let i = (axis == .vertical ? along * width + across : across * width + along) * 4
                    var difference = 0, luminance = 0
                    for channel in 0..<3 {
                        difference += abs(Int(first[i + channel]) - Int(second[i + channel]))
                        luminance += Int(first[i + channel])
                    }
                    error += difference; samples += 1
                    if difference > 16 * 3 { changed += 1 }
                    low = min(low, luminance / 3); high = max(high, luminance / 3)
                }
            }
            let matches = Double(error) / Double(samples * 3) < 3 && Double(changed) / Double(samples) < 0.1
            if high - low >= 12 {
                textured += 1
                if matches { agreeingTextured += 1 }
            }
            if !matches { rejected.append(lane) }
        }
        // Only a localized minority may differ. Blank margins do not provide
        // positive evidence, and dispersed changes are not one local video.
        guard let firstRejected = rejected.first, let lastRejected = rejected.last,
              lastRejected - firstRejected + 1 <= lanes / 3,
              agreeingTextured >= max(3, Int(ceil(Double(textured) * 0.6))) else { return false }
        return true
    }

    private static func similar(_ a: CGImage, _ b: CGImage) throws -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let width = min(192, a.width), height = min(192, a.height)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height)
            let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.interpolationQuality = .low
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard drawn else { throw CaptureError.message(L10n.text("无法核对固定栏与正文，已截内容保留。")) }
            return data
        }
        try Task.checkCancellation()
        let first = try pixels(a), second = try pixels(b)
        var total = 0, changed = 0
        for i in first.indices {
            let error = abs(Int(first[i]) - Int(second[i]))
            total += error; if error > 16 { changed += 1 }
        }
        return Double(total) / Double(first.count) < 9 && Double(changed) / Double(first.count) < 0.35
    }

    static func detect(previous: CGImage, next: CGImage, axis: ScrollAxis, offset: Int) -> ScrollFixedEdges {
        guard previous.width == next.width, previous.height == next.height, offset > 0 else { return .none }
        let length = axis == .vertical ? previous.height : previous.width
        guard length >= 40 else { return .none }
        func pixels(_ image: CGImage, crossLength: Int) -> [UInt8] {
            let w = axis == .vertical ? crossLength : length, h = axis == .vertical ? length : crossLength
            var data = [UInt8](repeating: 0, count: w * h)
            data.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
                context.interpolationQuality = .none; context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return data
        }
        let a = pixels(previous, crossLength: 64), b = pixels(next, crossLength: 64)
        func edge(_ a: [UInt8], _ b: [UInt8], crossLength: Int, reverse: Bool) -> Int {
            func value(_ data: [UInt8], _ row: Int, _ cross: Int) -> Int {
                Int(data[axis == .vertical ? row * crossLength + cross : cross * length + row])
            }
            var count = 0, low = 255, high = 0, texturedRows = 0
            // Browser chrome plus a sticky site header can exceed a quarter of
            // the frame. A suggestion still requires a textured stationary bar
            // with a real moving boundary; body matching validates the result.
            let limit = max(4, length * 3 / 5)
            for index in 0..<limit {
                let row = reverse ? length - index - 1 : index
                if (0..<crossLength).contains(where: { abs(value(a, row, $0) - value(b, row, $0)) > 2 }) { break }
                var rowLow = 255, rowHigh = 0
                for cross in 0..<crossLength {
                    let pixel = value(a, row, cross)
                    low = min(low, pixel); high = max(high, pixel)
                    rowLow = min(rowLow, pixel); rowHigh = max(rowHigh, pixel)
                }
                if rowHigh-rowLow >= 12 { texturedRows += 1 }
                count += 1
            }
            // Whole blank/repeating regions and a boundary outside the bounded
            // scan are not evidence of a fixed bar. Suggest, never silently delete.
            // A separator plus stationary blank padding is not a textured
            // whole bar. Require evidence on several cross-sections rather
            // than a larger arbitrary minimum height.
            return count >= 4 && count < limit && high - low >= 12 && texturedRows >= 4 ? count : 0
        }
        let coarse = ScrollFixedEdges(leading: edge(a, b, crossLength: 64, reverse: false), trailing: edge(a, b, crossLength: 64, reverse: true))
        guard !coarse.isEmpty else { return .none }
        // Repeated text can appear identical after downsampling. A whole fixed
        // edge must also remain stationary at the original cross resolution.
        let crossLength = axis == .vertical ? previous.width : previous.height
        let original = pixels(previous, crossLength: crossLength), current = pixels(next, crossLength: crossLength)
        let found = ScrollFixedEdges(leading: coarse.leading == 0 ? 0 : min(coarse.leading, edge(original, current, crossLength: crossLength, reverse: false)),
                                     trailing: coarse.trailing == 0 ? 0 : min(coarse.trailing, edge(original, current, crossLength: crossLength, reverse: true)))
        return found.valid(length: length) ? found : .none
    }
}
