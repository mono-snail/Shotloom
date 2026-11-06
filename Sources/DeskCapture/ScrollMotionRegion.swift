import AppKit

/// Finds translation evidence inside a window instead of asking its stationary
/// chrome to translate too. Coordinates are in the original capture's pixels.
enum ScrollMotionRegion {
    struct Proposal {
        let crossRange: Range<Int>
        let edges: ScrollFixedEdges
        let offset: Int
    }

    static func crossCrop(_ image: CGImage, range: Range<Int>, axis: ScrollAxis) -> CGImage? {
        let cross = axis == .vertical ? image.width : image.height
        guard range.lowerBound >= 0, range.upperBound <= cross, !range.isEmpty else { return nil }
        return image.cropping(to: axis == .vertical
            ? CGRect(x: range.lowerBound, y: 0, width: range.count, height: image.height)
            : CGRect(x: 0, y: range.lowerBound, width: image.width, height: range.count))
    }

    static func detect(previous: CGImage, next: CGImage, axis: ScrollAxis,
                       direction: ScrollDirection) throws -> Proposal? {
        guard previous.width == next.width, previous.height == next.height else { return nil }
        let length = axis == .vertical ? previous.height : previous.width
        let cross = axis == .vertical ? previous.width : previous.height
        guard length >= 80, cross >= 96 else { return nil }
        let lanes = min(16, cross / 16)
        let samples = lanes * 12
        let w = axis == .vertical ? samples : length
        let h = axis == .vertical ? length : samples
        func pixels(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: w * h)
            let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
                guard let context = CGContext(data: memory.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return drawn ? bytes : nil
        }
        guard let a = pixels(previous), let b = pixels(next) else { return nil }
        func value(_ bytes: [UInt8], row: Int, column: Int) -> Int {
            Int(bytes[axis == .vertical ? row * samples + column : column * length + row])
        }
        var matches: [(lane: Int, edges: ScrollFixedEdges, offset: Int)] = []
        for lane in 0..<lanes {
            try Task.checkCancellation()
            var first: Int?, last = 0, changedRows = 0
            for row in 0..<length {
                let changed = (lane * 12..<(lane + 1) * 12).filter {
                    abs(value(a, row: row, column: $0) - value(b, row: row, column: $0)) > 8
                }.count
                if changed >= 2 {
                    if first == nil { first = row }
                    last = row; changedRows += 1
                }
            }
            guard let first, changedRows >= max(24, length / 16) else { continue }
            let edges = ScrollFixedEdges(leading: first, trailing: length - last - 1)
            guard edges.valid(length: length), length - edges.leading - edges.trailing >= 80 else { continue }
            let range = lane * cross / lanes..<(lane + 1) * cross / lanes
            guard let prior = crossCrop(previous, range: range, axis: axis),
                  let current = crossCrop(next, range: range, axis: axis),
                  let priorBody = prior.cropping(to: edges.bodyRect(prior, axis: axis)),
                  let currentBody = current.cropping(to: edges.bodyRect(current, axis: axis)),
                  let match = ScrollMatcher.match(previous: priorBody, next: currentBody, axis: axis, direction: direction),
                  match.offset > 0 else { continue }
            matches.append((lane, edges, match.offset))
        }
        // Two adjacent, independently matched strips must agree exactly. A
        // second moving pane with a different displacement is not one document.
        guard matches.count >= 2, let first = matches.first,
              matches.allSatisfy({ $0.offset == first.offset }),
              matches.contains(where: { entry in matches.contains(where: { $0.lane == entry.lane + 1 }) }) else { return nil }
        let lower = matches.map(\.lane).min()! * cross / lanes
        let upper = (matches.map(\.lane).max()! + 1) * cross / lanes
        let range = lower..<upper
        let edges = ScrollFixedEdges(leading: matches.map(\.edges.leading).min()!,
                                     trailing: matches.map(\.edges.trailing).min()!)
        guard let prior = crossCrop(previous, range: range, axis: axis),
              let current = crossCrop(next, range: range, axis: axis),
              let priorBody = prior.cropping(to: edges.bodyRect(prior, axis: axis)),
              let currentBody = current.cropping(to: edges.bodyRect(current, axis: axis)),
              let combined = ScrollMatcher.match(previous: priorBody, next: currentBody, axis: axis, direction: direction),
              combined.offset == first.offset,
              try ScrollFixedEdgeDetector.bodyBoundariesAgree(previous: prior, next: current, edges: edges,
                  axis: axis, direction: direction, offset: combined.offset) else { return nil }
        // Stationary repeated headlines must not be silently removed. Require
        // the same ambiguity check as full-width fixed-bar detection.
        if !edges.isEmpty {
            guard try ScrollFixedEdgeDetector.supportsAutomaticResolution(previous: prior, next: current, edges: edges,
                axis: axis, direction: direction, offset: combined.offset) else { return nil }
        }
        return Proposal(crossRange: range, edges: edges, offset: combined.offset)
    }
}
