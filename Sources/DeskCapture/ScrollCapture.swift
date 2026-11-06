import AppKit
import ScreenCaptureKit
import Combine

struct ScrollMatch {
    let offset: Int
    let error: Double
}

enum ScrollAxis { case vertical, horizontal }
enum ScrollDirection: String, CaseIterable, Identifiable {
    case forward, reverse
    var id: String { rawValue }
    func movementTitle(axis: ScrollAxis) -> String {
        if axis == .vertical { return self == .reverse ? L10n.text("向上") : L10n.text("向下") }
        return self == .reverse ? L10n.text("向左") : L10n.text("向右")
    }
    func recoveryTitle(axis: ScrollAxis) -> String {
        (self == .reverse ? ScrollDirection.forward : .reverse).movementTitle(axis: axis)
    }
}

enum ScrollCaptureOrientation: String, CaseIterable, Identifiable {
    case down, up, right, left
    var id: Self { self }
    var axis: ScrollAxis { self == .down || self == .up ? .vertical : .horizontal }
    var direction: ScrollDirection { self == .up || self == .left ? .reverse : .forward }
    var title: String { direction.movementTitle(axis: axis) }
    var symbol: String {
        switch self { case .down: "arrow.down"; case .up: "arrow.up"; case .right: "arrow.right"; case .left: "arrow.left" }
    }
}

struct ScrollPreviewTile: Identifiable {
    let id: Int
    let image: CGImage
    let sourceHeight: Int
    let sourceWidth: Int
}

struct ScrollPreview {
    var axis: ScrollAxis = .vertical
    var direction: ScrollDirection = .forward
    var tiles: [ScrollPreviewTile] = []
    var width = 0
    var height = 0
    var lastIncrement = 0
}

private enum ScrollExportResult { case image(CGImage), file(URL) }

enum ScrollCaptureOutput {
    case clipboard
    case editor
    case file(URL)
    case segments(URL)
}

enum CaptureImageExport {
    static func write(_ image: CGImage, to url: URL) throws {
        try Task.checkCancellation()
        let type: CFString
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": type = "public.jpeg" as CFString
        case "tif", "tiff": type = "public.tiff" as CFString
        case "heic": type = "public.heic" as CFString
        case "pdf": try pdf(image, to: url); return
        default: try png(image, to: url); return
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw CaptureError.message(L10n.text("此系统暂不支持这个图片格式。"))
        }
        var encoded = image
        if type as String == "public.jpeg" {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CaptureError.message(L10n.text("图片编码失败。")) }
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let flattened = context.makeImage() else { throw CaptureError.message(L10n.text("图片编码失败。")) }
            encoded = flattened
        }
        CGImageDestinationAddImage(destination, encoded, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.message(L10n.text("图片编码失败。")) }
        try Task.checkCancellation()
        try writeEncoded(data as Data, to: url)
    }
    static func png(_ image: CGImage, to url: URL) throws {
        try Task.checkCancellation()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureError.message(L10n.text("图片编码失败。"))
        }
        try Task.checkCancellation()
        try writeEncoded(data, to: url)
    }
    /// Stage the disk write separately from the commit so cancellation during
    /// a large write cannot replace an existing destination afterwards.
    static func writeEncoded(_ data: Data, to url: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        let stage = url.deletingLastPathComponent().appendingPathComponent(".DeskCapture-output-\(UUID())")
        defer { try? manager.removeItem(at: stage) }
        try data.write(to: stage, options: .withoutOverwriting)
        try beforeCommit?()
        try Task.checkCancellation()
        if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: stage) }
        else { try manager.moveItem(at: stage, to: url) }
    }
    static func pdf(_ image: CGImage, to url: URL, axis: ScrollAxis = .vertical) throws {
        let stage = url.deletingLastPathComponent().appendingPathComponent(".DeskCapture-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: stage) }
        try renderPDF(image, to: stage, axis: axis)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: url) }
    }
    private static func renderPDF(_ image: CGImage, to url: URL, axis: ScrollAxis) throws {
        var page = axis == .vertical
            ? CGRect(x: 0, y: 0, width: 595, height: 842)
            : CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw CaptureError.message(L10n.text("无法创建 PDF 文件。"))
        }
        defer { context.closePDF() }
        let margin: CGFloat = 28
        if axis == .horizontal {
            let scale = (page.height - 2 * margin) / CGFloat(image.height)
            let columnsPerPage = max(1, Int(floor((page.width - 2 * margin) / scale)))
            for start in stride(from: 0, to: image.width, by: columnsPerPage) {
                try Task.checkCancellation()
                let count = min(columnsPerPage, image.width - start)
                guard let strip = image.cropping(to: CGRect(x: start, y: 0, width: count, height: image.height)) else {
                    throw CaptureError.message(L10n.text("PDF 分页裁剪失败。"))
                }
                context.beginPDFPage(nil)
                context.setFillColor(NSColor.white.cgColor); context.fill(page)
                context.draw(strip, in: CGRect(x: margin, y: margin, width: CGFloat(count) * scale,
                                               height: page.height - 2 * margin))
                context.endPDFPage()
            }
            return
        }
        let scale = (page.width - 2 * margin) / CGFloat(image.width)
        let rowsPerPage = max(1, Int(floor((page.height - 2 * margin) / scale)))
        for start in stride(from: 0, to: image.height, by: rowsPerPage) {
            try Task.checkCancellation()
            let count = min(rowsPerPage, image.height - start)
            guard let strip = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: count)) else {
                throw CaptureError.message(L10n.text("PDF 分页裁剪失败。"))
            }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(page)
            context.draw(strip, in: CGRect(x: margin, y: page.height - margin - CGFloat(count) * scale,
                                           width: page.width - 2 * margin, height: CGFloat(count) * scale))
            context.endPDFPage()
        }
    }
}

enum ScrollCaptureSpeed: String, CaseIterable, Identifiable {
    case slow, standard, fast
    var id: String { rawValue }
    var title: String {
        switch self { case .slow: return L10n.text("慢速 · 动态页面"); case .standard: return L10n.text("标准"); case .fast: return L10n.text("快速 · 静态页面") }
    }
    var delayMilliseconds: Int {
        switch self { case .slow: return 1100; case .standard: return 600; case .fast: return 450 }
    }
    func step(for length: CGFloat) -> Int32 {
        let fraction: CGFloat, cap: CGFloat
        switch self {
        case .slow: fraction = 0.14; cap = 90
        case .standard: fraction = 0.22; cap = 160
        case .fast: fraction = 0.40; cap = 320
        }
        return Int32(max(4, min(cap, length * fraction)))
    }
}

struct ScrollCaptureProgress {
    private(set) var failures = 0
    private(set) var unchanged = 0
    private(set) var needsSeamRecovery = false
    private(set) var awaitingResponse = false
    var shouldScroll: Bool { !needsSeamRecovery && !awaitingResponse }
    mutating func didScroll() { awaitingResponse = true; unchanged = 0 }
    mutating func resetCounters() { failures = 0; unchanged = 0 }
    mutating func resumeAtCurrentPosition() { awaitingResponse = false; resetCounters() }
    mutating func observe(_ increment: Int?) {
        guard let increment else {
            needsSeamRecovery = true; failures += 1; unchanged = 0
            return
        }
        needsSeamRecovery = false; failures = 0
        if increment > 0 { awaitingResponse = false }
        unchanged = increment == 0 ? unchanged + 1 : 0
    }
}

enum ScrollCaptureStopReason: Equatable {
    case boundary, unresponsive, unconfirmed
    static func stationary(evidence: ScrollPositionEvidence?, direction: ScrollDirection) -> Self {
        guard let evidence, evidence.valid else { return .unconfirmed }
        return evidence.atBoundary(direction: direction) ? .boundary : .unresponsive
    }
    var title: String {
        switch self {
        case .boundary: L10n.text("到达边界")
        case .unresponsive: L10n.text("尚未滚动")
        case .unconfirmed: L10n.text("未再滚动")
        }
    }
}

enum ScrollAutomationAvailability {
    #if APP_STORE
    static let enabled = false
    #else
    static let enabled = true
    #endif
}

enum ScrollAutomationEvent {
    static func make(rect: CGRect, screenFrame: CGRect, desktopTop: CGFloat, axis: ScrollAxis = .vertical,
                     speed: ScrollCaptureSpeed = .standard, direction: ScrollDirection = .forward, targetWindowID: CGWindowID? = nil) -> CGEvent? {
        #if APP_STORE
        return nil
        #else
        let step = speed.step(for: axis == .vertical ? rect.height : rect.width)
        let delta = direction == .reverse ? step : -step
        let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
                            wheelCount: axis == .vertical ? 1 : 2,
                            wheel1: axis == .vertical ? delta : 0, wheel2: axis == .horizontal ? delta : 0, wheel3: 0)
        event?.location = CGPoint(x: screenFrame.minX + rect.midX, y: desktopTop - screenFrame.minY - rect.midY)
        if let targetWindowID {
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(targetWindowID))
            event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(targetWindowID))
        }
        return event
        #endif
    }
}

enum ScrollMatcher {
    static func grayscale(_ image: CGImage, width: Int = 96) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        return pixels
    }
    private static func horizontalGrayscale(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = 96
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
    static func match(previous: CGImage, next: CGImage, axis: ScrollAxis = .vertical,
                      direction: ScrollDirection = .forward) -> ScrollMatch? {
        // Reverse capture uses the same conservative overlap validation with
        // swapped frames, rather than inventing a seam from a reversed wheel.
        if direction == .reverse { return match(previous: next, next: previous, axis: axis) }
        guard previous.width == next.width, previous.height == next.height,
              (axis == .vertical ? previous.height : previous.width) >= 40 else { return nil }
        let length = axis == .vertical ? previous.height : previous.width
        let a = axis == .vertical ? grayscale(previous) : horizontalGrayscale(previous)
        let b = axis == .vertical ? grayscale(next) : horizontalGrayscale(next)
        let maxOffset = Int(Double(length) * 0.78)
        func value(_ bytes: [UInt8], primary: Int, cross: Int) -> UInt8 {
            axis == .vertical ? bytes[primary * 96 + cross] : bytes[cross * length + primary]
        }
        let stationaryRows = (0..<length).map { row in
            stride(from: 8, to: 88, by: 8).allSatisfy {
                value(a, primary: row, cross: $0) == value(b, primary: row, cross: $0)
            }
        }
        func score(_ offset: Int) -> Double {
            let margin = max(2, length / 12), end = length - offset - margin
            guard end > margin else { return 255 }
            // Local video/animation must not spoil the error for the whole
            // overlap. Keep a majority of agreeing blocks, with textured
            // evidence so large blank margins cannot establish a false seam.
            var sums = [Int](repeating: 0, count: 140)
            var counts = sums
            var lows = [Int](repeating: 255, count: 140)
            var highs = [Int](repeating: 0, count: 140)
            for position in stride(from: margin, to: end, by: max(1, (end - margin) / 70)) {
                if offset > 0 && stationaryRows[position] { continue }
                for cross in stride(from: 8, to: 88, by: 2) {
                    let block = min(6, (position - margin) * 7 / (end - margin)) * 20 + (cross - 8) / 4
                    let prior = Int(value(a, primary: position + offset, cross: cross))
                    let next = Int(value(b, primary: position, cross: cross))
                    sums[block] += abs(prior - next); counts[block] += 1
                    lows[block] = min(lows[block], prior); highs[block] = max(highs[block], prior)
                }
            }
            let blocks = counts.indices.filter { counts[$0] > 0 }
            guard !blocks.isEmpty else { return 255 }
            let textured = blocks.filter { highs[$0] - lows[$0] >= 12 }
            if offset > 0 {
                let agreeing = textured.filter { Double(sums[$0]) / Double(counts[$0]) < 9 }
                guard agreeing.count >= max(4, Int(ceil(Double(textured.count) * 0.55))) else { return 255 }
            }
            let evidence = textured.isEmpty ? blocks : textured
            let errors = evidence.map { Double(sums[$0]) / Double(counts[$0]) }.sorted()
            let retained = max(1, Int(ceil(Double(errors.count) * 0.65)))
            return errors.prefix(retained).reduce(0, +) / Double(retained)
        }
        // Identical scanlines vote for exact pixel offsets. This stays fast on
        // tall captures and is robust to fixed headers, which vote for zero
        // while the larger scrolling region votes for its true displacement.
        func signature(_ bytes: [UInt8], row: Int) -> UInt64 {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for cross in stride(from: 8, to: 88, by: 8) {
                hash = (hash ^ UInt64(value(bytes, primary: row, cross: cross))) &* 1_099_511_628_211
            }
            return hash
        }
        var indexed: [UInt64: [Int]] = [:]
        for row in 0..<length {
            if row % 256 == 0 && Task.isCancelled { return nil }
            let key = signature(a, row: row)
            if (indexed[key]?.count ?? 0) < 9 { indexed[key, default: []].append(row) }
        }
        var votes: [Int: Int] = [:]
        for row in 0..<length {
            guard let found = indexed[signature(b, row: row)], found.count <= 8 else { continue }
            for prior in found where prior >= row && prior - row <= maxOffset { votes[prior - row, default: 0] += 1 }
        }
        var offsets = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(16).map(\.key)
        if !offsets.contains(0) { offsets.append(0) }
        var candidates = offsets.map { ScrollMatch(offset: $0, error: score($0)) }
        candidates.sort { $0.error == $1.error ? $0.offset < $1.offset : $0.error < $1.error }
        // A video or animated sidebar can change every whole-row signature.
        // Independent bands let the unchanged content propose an exact offset;
        // all proposals still go through the same textured-overlap validation.
        if candidates.first?.error ?? 255 >= 9 {
            for band in 0..<5 {
                if Task.isCancelled { return nil }
                func bandSignature(_ bytes: [UInt8], row: Int) -> UInt64 {
                    var hash: UInt64 = 14_695_981_039_346_656_037
                    for cross in stride(from: 8 + band * 16, to: 24 + band * 16, by: 4) {
                        hash = (hash ^ UInt64(value(bytes, primary: row, cross: cross))) &* 1_099_511_628_211
                    }
                    return hash
                }
                var bandIndex: [UInt64: [Int]] = [:]
                for row in 0..<length {
                    let key = bandSignature(a, row: row)
                    if (bandIndex[key]?.count ?? 0) < 9 { bandIndex[key, default: []].append(row) }
                }
                for row in 0..<length {
                    guard let found = bandIndex[bandSignature(b, row: row)], found.count <= 8 else { continue }
                    for prior in found where prior >= row && prior - row <= maxOffset {
                        votes[prior - row, default: 0] += 1
                    }
                }
            }
            let proposed = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(16).map(\.key)
            let additional = proposed.filter { !offsets.contains($0) }
            candidates += additional.map { ScrollMatch(offset: $0, error: score($0)) }
            candidates.sort { $0.error == $1.error ? $0.offset < $1.offset : $0.error < $1.error }
        }
        // Fractional scrolling or animated content may leave no exact row
        // fingerprints; retain the exhaustive matcher as a correctness path.
        if candidates.first?.error ?? 255 >= 9 {
            candidates = []
            for offset in 0...maxOffset {
                if offset % 16 == 0 && Task.isCancelled { return nil }
                candidates.append(ScrollMatch(offset: offset, error: score(offset)))
            }
            candidates.sort { $0.error == $1.error ? $0.offset < $1.offset : $0.error < $1.error }
        }
        guard let refined = candidates.first else { return nil }
        guard refined.error < 9 else { return nil }
        // Repeated/blank content cannot reliably establish an offset. Don't invent a seam.
        let ambiguous = candidates.first(where: { abs($0.offset-refined.offset) > 15 })
        let repeatedRows = refined.offset > 0 ? (0..<length).filter {
            (indexed[signature(a, row: $0)]?.count ?? 0) >= 9
        }.count : 0
        let ambiguousScore = ambiguous.map { $0.error <= refined.error+0.5 } ?? false
        if refined.offset > 0 && (ambiguousScore || repeatedRows*2 >= length) {
            // Sparse text can repeat the same line shape while its small row
            // numbers disappear in the 96-pixel proposal image. Resolve only
            // with denser whole-overlap evidence; repeated text stays rejected.
            let crossLength = min(384, axis == .vertical ? previous.width : previous.height)
            func dense(_ image: CGImage) -> [UInt8] {
                if axis == .vertical { return grayscale(image, width: crossLength) }
                var bytes = [UInt8](repeating: 0, count: length * crossLength)
                bytes.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: length, height: crossLength,
                                            bitsPerComponent: 8, bytesPerRow: length,
                                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                    context.interpolationQuality = .low
                    context.draw(image, in: CGRect(x: 0, y: 0, width: length, height: crossLength))
                }
                return bytes
            }
            let prior = dense(previous), current = dense(next)
            func denseSignature(_ bytes: [UInt8], row: Int) -> UInt64 {
                var hash: UInt64 = 14_695_981_039_346_656_037
                for cross in 0..<crossLength {
                    let index = axis == .vertical ? row*crossLength+cross : cross*length+row
                    hash = (hash ^ UInt64(bytes[index])) &* 1_099_511_628_211
                }
                return hash
            }
            let priorKeys = (0..<length).map { denseSignature(prior, row: $0) }
            let currentKeys = (0..<length).map { denseSignature(current, row: $0) }
            let priorCounts = Dictionary(grouping: priorKeys, by: { $0 }).mapValues { $0.count }
            let currentCounts = Dictionary(grouping: currentKeys, by: { $0 }).mapValues { $0.count }
            var proposals = Set(candidates.filter { $0.error < 9 }.flatMap { candidate in
                (max(0, candidate.offset - 2)...min(maxOffset, candidate.offset + 2))
            })
            // Aliased coarse rows can crowd the true offset out of the voting
            // shortlist. Distinctive dense rows must also be able to propose it.
            var uniqueIndex: [UInt64: Int] = [:], denseVotes: [Int: Int] = [:]
            for (row, key) in priorKeys.enumerated() where priorCounts[key] == 1 { uniqueIndex[key] = row }
            for (row, key) in currentKeys.enumerated() where currentCounts[key] == 1 {
                if row % 256 == 0, Task.isCancelled { return nil }
                if let before = uniqueIndex[key], before >= row, before-row <= maxOffset {
                    denseVotes[before-row, default: 0] += 1
                }
            }
            let denseProposals = denseVotes.filter { $0.value >= 8 }.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.prefix(8).map(\.key)
            proposals.formUnion(denseProposals)
            var details: [ScrollMatch] = []
            for offset in proposals {
                if Task.isCancelled { return nil }
                let margin = max(2, length / 12), end = length - offset - margin
                guard end > margin else { continue }
                // A short repeated sentence may have zero error. Require
                // distinctive exact rows spread across the overlap, rather
                // than rewarding that smaller comparison area.
                var uniqueRows = 0, bands: Set<Int> = []
                for position in 0..<length-offset {
                    let key = currentKeys[position]
                    if key == priorKeys[position+offset], priorCounts[key] == 1, currentCounts[key] == 1 {
                        uniqueRows += 1; bands.insert(position*7/(length-offset))
                    }
                }
                guard uniqueRows >= 8, bands.count >= 3 else { continue }
                var sum: UInt64 = 0, count = 0
                for position in stride(from: margin, to: end, by: max(1, (end-margin)/350)) {
                    for cross in 0..<crossLength {
                        let aIndex = axis == .vertical ? (position+offset)*crossLength+cross : cross*length+position+offset
                        let bIndex = axis == .vertical ? position*crossLength+cross : cross*length+position
                        let neighbor = axis == .vertical ? 1 : length
                        // Blank background must not dilute the few differing
                        // glyphs which distinguish otherwise repeated lines.
                        if cross > 0 && cross < crossLength - 1 &&
                           max(abs(Int(prior[aIndex])-Int(prior[aIndex-neighbor])),
                               abs(Int(prior[aIndex])-Int(prior[aIndex+neighbor])),
                               abs(Int(current[bIndex])-Int(current[bIndex-neighbor])),
                               abs(Int(current[bIndex])-Int(current[bIndex+neighbor]))) >= 8 {
                            sum += UInt64(abs(Int(prior[aIndex])-Int(current[bIndex]))); count += 1
                        }
                    }
                }
                if count >= 128 { details.append(ScrollMatch(offset: offset, error: Double(sum)/Double(count))) }
            }
            details.sort { $0.error == $1.error ? $0.offset < $1.offset : $0.error < $1.error }
            guard let best = details.first, best.error < 3 else { return nil }
            if let alternative = details.first(where: { abs($0.offset-best.offset) > 15 }),
               alternative.error <= max(best.error + 0.5, best.error * 3) { return nil }
            return best
        }
        return refined
    }
}

final class ScrollStitcher {
    private(set) var totalHeight = 0
    private(set) var totalWidth = 0
    private(set) var width = 0
    private(set) var frameCount = 0
    let axis: ScrollAxis
    let direction: ScrollDirection
    let fixedEdges: ScrollFixedEdges
    private let detectsFixedEdges: Bool
    private let matchingCrossRange: Range<Int>?
    private(set) var suggestedFixedEdges: ScrollFixedEdges?
    private var lastImage: CGImage?
    private var tiles: [(url: URL, frameURL: URL, length: Int)] = []
    var canRemoveLast: Bool { tiles.count > 1 }
    private(set) var preview = ScrollPreview()
    let directory: URL
    init(axis: ScrollAxis = .vertical, direction: ScrollDirection = .forward, fixedEdges: ScrollFixedEdges = .none,
         detectsFixedEdges: Bool = true, matchingCrossRange: Range<Int>? = nil,
         directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-scroll-\(UUID().uuidString)")) throws {
        self.axis = axis; self.direction = direction
        self.fixedEdges = fixedEdges; self.detectsFixedEdges = detectsFixedEdges
        self.matchingCrossRange = matchingCrossRange
        preview.axis = axis; preview.direction = direction
        self.directory = directory; try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    @discardableResult
    func append(_ image: CGImage) throws -> Int? {
        try Task.checkCancellation()
        guard Double(image.width) * Double(image.height) <= 80_000_000, max(image.width, image.height) <= 60_000 else { throw CaptureError.message(L10n.text("长图帧超过容量上限。")) }
        if lastImage == nil {
            let length = axis == .vertical ? image.height : image.width
            guard fixedEdges.valid(length: length), let body = image.cropping(to: bodyRect(image)) else {
                throw CaptureError.message(L10n.text("固定栏范围无效，正文至少需要 20 像素。"))
            }
            width = image.width; totalWidth = 0; totalHeight = 0
            try save(body, frame: image); lastImage = image
            return axis == .vertical ? image.height : image.width
        }
        guard let lastImage else { return nil }
        suggestedFixedEdges = nil
        if let proposal = fixedEdgeProposal(image) {
            suggestedFixedEdges = proposal.edges
            return nil
        }
        let candidate = matchBody(previous: lastImage, next: image)
        try Task.checkCancellation()
        guard let match = candidate else { return nil }
        if match.offset == 0 { return 0 }
        let bodyLength = (axis == .vertical ? image.height : image.width) - fixedEdges.leading - fixedEdges.trailing
        if !fixedEdges.isEmpty {
            guard match.offset < bodyLength - 10 else { return nil }
            // The body overlap is the evidence. Header hover, antialiasing or
            // a changed clock must not invalidate an otherwise correct seam.
            guard let priorEvidence = matchingImage(lastImage), let currentEvidence = matchingImage(image),
                  try ScrollFixedEdgeDetector.bodyBoundariesAgree(previous: priorEvidence, next: currentEvidence, edges: fixedEdges,
                axis: axis, direction: direction, offset: match.offset) else {
                throw CaptureError.message(L10n.text("暂时找不到可靠的衔接位置，已暂停，已截内容保留。可保存当前长图，或滚回预览末尾的位置后继续。"))
            }
        }
        let sum = (axis == .vertical ? totalHeight : totalWidth).addingReportingOverflow(match.offset)
        guard !sum.overflow else { throw CaptureError.message(L10n.text("长图尺寸超过索引范围，原内容保留。")) }
        let nextWidth = axis == .vertical ? width : sum.partialValue
        let nextHeight = axis == .vertical ? sum.partialValue : totalHeight
        guard nextWidth > 0, nextHeight > 0, !nextWidth.multipliedReportingOverflow(by: nextHeight).overflow else { throw CaptureError.message(L10n.text("长图尺寸超过索引范围，已保留当前内容。")) }
        let crop = axis == .vertical
            ? CGRect(x: 0, y: direction == .reverse ? fixedEdges.leading : image.height - fixedEdges.trailing - match.offset, width: image.width, height: match.offset)
            : CGRect(x: direction == .reverse ? fixedEdges.leading : image.width - fixedEdges.trailing - match.offset, y: 0, width: match.offset, height: image.height)
        guard let addition = image.cropping(to: crop) else {
            throw CaptureError.message(L10n.text("无法裁剪新增长图内容。"))
        }
        try save(addition, frame: image); self.lastImage = image; return match.offset
    }
    @discardableResult
    func removeLast() throws -> Int {
        guard canRemoveLast, let removed = tiles.last, let prior = tiles.dropLast().last,
              let source = CGImageSourceCreateWithURL(prior.frameURL as CFURL, nil),
              let previous = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.message(L10n.text("没有可撤回的长图分段。"))
        }
        try Task.checkCancellation()
        tiles.removeLast()
        if direction == .reverse { preview.tiles.remove(at: fixedEdges.leading > 0 ? 1 : 0) }
        else { preview.tiles.remove(at: preview.tiles.count - (fixedEdges.trailing > 0 ? 2 : 1)) }
        if axis == .vertical { totalHeight -= removed.length } else { totalWidth -= removed.length }
        frameCount -= 1
        preview.width = totalWidth; preview.height = totalHeight; preview.lastIncrement = prior.length
        lastImage = previous
        try? FileManager.default.removeItem(at: removed.url)
        try? FileManager.default.removeItem(at: removed.frameURL)
        return removed.length
    }
    private func save(_ image: CGImage, frame: CGImage) throws {
        // Keep a narrow thumbnail of each accepted strip; never render the full
        // export bitmap for live UI updates. Duplicate/rejected frames add nothing.
        let previewWidth = axis == .vertical ? min(240, image.width)
            : max(1, Int((Double(image.width) * Double(min(240, image.height)) / Double(image.height)).rounded()))
        let previewHeight = axis == .vertical
            ? max(1, Int((Double(image.height) * Double(previewWidth) / Double(image.width)).rounded()))
            : min(240, image.height)
        guard let ctx = CGContext(data: nil, width: previewWidth, height: previewHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("无法创建长图预览。当前内容已保留。"))
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight))
        guard let thumbnail = ctx.makeImage() else { throw CaptureError.message(L10n.text("无法创建长图预览。")) }
        var edgePreviews: [ScrollPreviewTile] = []
        if frameCount == 0 {
            for (start, length, id) in [(0, fixedEdges.leading, -1), ((axis == .vertical ? frame.height : frame.width) - fixedEdges.trailing, fixedEdges.trailing, -2)] where length > 0 {
                let crop = axis == .vertical ? CGRect(x: 0, y: start, width: frame.width, height: length) : CGRect(x: start, y: 0, width: length, height: frame.height)
                if let bar = frame.cropping(to: crop) {
                    let bw = axis == .vertical ? min(240, bar.width) : max(1, Int(Double(bar.width) * Double(min(240, bar.height)) / Double(bar.height)))
                    let bh = axis == .vertical ? max(1, Int(Double(bar.height) * Double(bw) / Double(bar.width))) : min(240, bar.height)
                    guard let context = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.message(L10n.text("无法创建固定栏预览，已有内容保留。")) }
                    context.draw(bar, in: CGRect(x: 0, y: 0, width: bw, height: bh))
                    guard let thumbnail = context.makeImage() else { throw CaptureError.message(L10n.text("无法创建固定栏预览。")) }
                    let edgeTile = ScrollPreviewTile(id: id, image: thumbnail, sourceHeight: bar.height, sourceWidth: bar.width)
                    edgePreviews.append(edgeTile)
                }
            }
        }
        let url = directory.appendingPathComponent("tile-\(tiles.count).png")
        let frameURL = directory.appendingPathComponent("frame-\(tiles.count).png")
        guard let data = autoreleasepool(invoking: { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) }) else { throw CaptureError.message(L10n.text("无法保存长图分块。")) }
        guard let frameData = autoreleasepool(invoking: { NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) }) else { throw CaptureError.message(L10n.text("无法保存长图原始帧。")) }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        do {
            try frameData.write(to: frameURL, options: .atomic)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: frameURL)
            throw error
        }
        let length = axis == .vertical ? image.height : image.width
        tiles.append((url, frameURL, length))
        if axis == .vertical { totalHeight += length; totalWidth = width }
        else { totalWidth += length; totalHeight = image.height }
        if frameCount == 0 {
            if axis == .vertical { totalHeight += fixedEdges.leading + fixedEdges.trailing }
            else { totalWidth += fixedEdges.leading + fixedEdges.trailing }
        }
        frameCount += 1
        let tile = ScrollPreviewTile(id: frameCount, image: thumbnail, sourceHeight: image.height, sourceWidth: image.width)
        if direction == .reverse { preview.tiles.insert(tile, at: preview.tiles.isEmpty ? 0 : fixedEdges.leading > 0 ? 1 : 0) }
        else { preview.tiles.insert(tile, at: max(0, preview.tiles.count - (frameCount > 1 && fixedEdges.trailing > 0 ? 1 : 0))) }
        if frameCount == 1 {
            for edge in edgePreviews {
                if edge.id == -1 { preview.tiles.insert(edge, at: 0) } else { preview.tiles.append(edge) }
            }
        }
        preview.width = totalWidth; preview.height = totalHeight; preview.lastIncrement = length
    }
    func render() throws -> CGImage {
        guard Double(totalWidth) * Double(totalHeight) <= 80_000_000, max(totalWidth, totalHeight) <= 60_000 else {
            throw CaptureError.message(L10n.text("长图超过整图容量，请选择分块 PNG 或分页 PDF，原片段已保留。"))
        }
        guard totalWidth > 0, totalHeight > 0,
              let ctx = CGContext(data: nil, width: totalWidth, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.message(L10n.text("没有可导出的长图。"))
        }
        var top = totalHeight - fixedEdges.leading, left = fixedEdges.leading
        if !fixedEdges.isEmpty, let first = tiles.first {
            guard let source = CGImageSourceCreateWithURL(first.frameURL as CFURL, nil), let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.message(L10n.text("固定栏原帧无法读取。")) }
            for (start, length, destination) in [(0, fixedEdges.leading, 0), ((axis == .vertical ? frame.height : frame.width) - fixedEdges.trailing, fixedEdges.trailing, (axis == .vertical ? totalHeight : totalWidth) - fixedEdges.trailing)] where length > 0 {
                let crop = axis == .vertical ? CGRect(x: 0, y: start, width: frame.width, height: length) : CGRect(x: start, y: 0, width: length, height: frame.height)
                guard let bar = frame.cropping(to: crop) else { throw CaptureError.message(L10n.text("固定栏无法读取。")) }
                ctx.draw(bar, in: axis == .vertical ? CGRect(x: 0, y: totalHeight - destination - length, width: totalWidth, height: length) : CGRect(x: destination, y: 0, width: length, height: totalHeight))
            }
        }
        let ordered = direction == .reverse ? Array(tiles.reversed()) : tiles
        for tile in ordered {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(tile.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CaptureError.message(L10n.text("长图分块无法读取。"))
            }
            if axis == .vertical {
                top -= tile.length
                ctx.draw(image, in: CGRect(x: 0, y: top, width: totalWidth, height: tile.length))
            } else {
                ctx.draw(image, in: CGRect(x: left, y: 0, width: tile.length, height: totalHeight))
                left += tile.length
            }
        }
        return ctx.makeImage()!
    }
    private func bodyRect(_ image: CGImage) -> CGRect {
        fixedEdges.bodyRect(image, axis: axis)
    }
    func exportPlan() throws -> ScrollExportPlan {
        guard let first = tiles.first, let lastImage else { throw CaptureError.message(L10n.text("没有可导出的片段。")) }
        var pieces: [ScrollRenderPiece] = []
        let primary = axis == .vertical ? totalHeight : totalWidth
        let framePrimary = axis == .vertical ? lastImage.height : lastImage.width
        for (start, length, destination) in [(0, fixedEdges.leading, 0), (framePrimary - fixedEdges.trailing, fixedEdges.trailing, primary - fixedEdges.trailing)] where length > 0 {
            let crop = axis == .vertical ? CGRect(x: 0, y: start, width: lastImage.width, height: length) : CGRect(x: start, y: 0, width: length, height: lastImage.height)
            let target = axis == .vertical ? CGRect(x: 0, y: destination, width: totalWidth, height: length) : CGRect(x: destination, y: 0, width: length, height: totalHeight)
            pieces.append(ScrollRenderPiece(url: first.frameURL, crop: crop, destination: target))
        }
        var position = fixedEdges.leading
        for tile in direction == .reverse ? Array(tiles.reversed()) : tiles {
            let crop = axis == .vertical ? CGRect(x: 0, y: 0, width: totalWidth, height: tile.length) : CGRect(x: 0, y: 0, width: tile.length, height: totalHeight)
            let target = axis == .vertical ? CGRect(x: 0, y: position, width: totalWidth, height: tile.length) : CGRect(x: position, y: 0, width: tile.length, height: totalHeight)
            pieces.append(ScrollRenderPiece(url: tile.url, crop: crop, destination: target)); position += tile.length
        }
        return ScrollExportPlan(width: totalWidth, height: totalHeight, axis: axis, pieces: pieces)
    }
    func reconfigured(edges: ScrollFixedEdges, crossRange: Range<Int>? = nil) throws -> ScrollStitcher {
        let replacement = try ScrollStitcher(axis: axis, direction: direction, fixedEdges: edges, detectsFixedEdges: false,
                                             matchingCrossRange: crossRange ?? matchingCrossRange)
        for tile in tiles {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(tile.frameURL as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  try replacement.append(image) != nil else { throw CaptureError.message(L10n.text("固定栏设置无法重建已有片段，原结果已保留。")) }
        }
        return replacement
    }
    func proposedOffset(_ image: CGImage) -> Int? {
        guard let lastImage else { return nil }
        let offset = fixedEdgeProposal(image)?.match.offset ?? matchBody(previous: lastImage, next: image)?.offset
        if let offset, offset > 0 { return offset }
        return (try? motionRegionProposal(image))?.offset ?? offset
    }
    private func matchingImage(_ image: CGImage) -> CGImage? {
        guard let matchingCrossRange else { return image }
        return ScrollMotionRegion.crossCrop(image, range: matchingCrossRange, axis: axis)
    }
    private func matchBody(previous: CGImage, next: CGImage) -> ScrollMatch? {
        guard let previous = matchingImage(previous), let next = matchingImage(next),
              previous.width == next.width, previous.height == next.height,
              let prior = previous.cropping(to: bodyRect(previous)), let current = next.cropping(to: bodyRect(next)) else { return nil }
        return ScrollMatcher.match(previous: prior, next: current, axis: axis, direction: direction)
    }
    private func motionRegionProposal(_ image: CGImage) throws -> ScrollMotionRegion.Proposal? {
        guard detectsFixedEdges, tiles.count == 1, let lastImage else { return nil }
        return try ScrollMotionRegion.detect(previous: lastImage, next: image, axis: axis, direction: direction)
    }
    func resolvingMotionRegion(_ image: CGImage) throws -> ScrollStitcher? {
        guard let proposal = try motionRegionProposal(image) else { return nil }
        return try reconfigured(edges: proposal.edges, crossRange: proposal.crossRange)
    }
    private func fixedEdgeProposal(_ image: CGImage) -> (edges: ScrollFixedEdges, match: ScrollMatch)? {
        guard detectsFixedEdges, fixedEdges.isEmpty, tiles.count == 1, let lastImage else { return nil }
        let edges = ScrollFixedEdgeDetector.detect(previous: lastImage, next: image, axis: axis, offset: 1)
        guard !edges.isEmpty, let prior = lastImage.cropping(to: edges.bodyRect(lastImage, axis: axis)),
              let current = image.cropping(to: edges.bodyRect(image, axis: axis)),
              let match = ScrollMatcher.match(previous: prior, next: current, axis: axis, direction: direction), match.offset > 0 else { return nil }
        return (edges, match)
    }
    func canResolveFixedEdgesAutomatically(_ image: CGImage, edges: ScrollFixedEdges) throws -> Bool {
        guard let lastImage, let proposal = fixedEdgeProposal(image), proposal.edges == edges else { return false }
        return try ScrollFixedEdgeDetector.supportsAutomaticResolution(previous: lastImage, next: image, edges: edges,
            axis: axis, direction: direction, offset: proposal.match.offset)
    }
}

/// Serial ownership keeps disk IO, PNG encoding and decoding off the UI actor.
/// Return a value snapshot so the UI never reads a mutating stitcher.
actor ScrollCaptureWorker {
    struct Update {
        let increment: Int?
        let preview: ScrollPreview
        let frames: Int
        var suggestedFixedEdges: ScrollFixedEdges? = nil
        var fixedEdges: ScrollFixedEdges = .none
        var targetThumbnail: CGImage? = nil
    }
    private var stitcher: ScrollStitcher
    private var targetThumbnail: CGImage?
    init(_ stitcher: ScrollStitcher) { self.stitcher = stitcher }
    func append(_ image: CGImage) throws -> Update {
        var increment = try stitcher.append(image)
        if let edges = stitcher.suggestedFixedEdges,
           try stitcher.canResolveFixedEdgesAutomatically(image, edges: edges) {
            // Rebuild and append against a separate owner. A failed/cancelled
            // candidate leaves every accepted tile in the original owner.
            let replacement = try stitcher.reconfigured(edges: edges)
            if let accepted = try replacement.append(image), accepted > 0 {
                try Task.checkCancellation()
                stitcher = replacement; increment = accepted
            }
        }
        if increment == nil || increment == 0,
           let replacement = try stitcher.resolvingMotionRegion(image),
           let accepted = try replacement.append(image), accepted > 0 {
            try Task.checkCancellation()
            stitcher = replacement; increment = accepted
        }
        if increment != 0 || targetThumbnail == nil {
            let scale = min(320.0 / Double(image.width), 220.0 / Double(image.height), 1)
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                targetThumbnail = context.makeImage()
            }
        }
        return Update(increment: increment, preview: stitcher.preview, frames: stitcher.frameCount,
                      suggestedFixedEdges: stitcher.suggestedFixedEdges, fixedEdges: stitcher.fixedEdges, targetThumbnail: targetThumbnail)
    }
    func removeLast() throws -> Update {
        try Task.checkCancellation()
        let increment = try stitcher.removeLast()
        return Update(increment: increment, preview: stitcher.preview, frames: stitcher.frameCount, fixedEdges: stitcher.fixedEdges)
    }
    func render() throws -> CGImage { try Task.checkCancellation(); return try stitcher.render() }
    func exportPlan() throws -> ScrollExportPlan { try Task.checkCancellation(); return try stitcher.exportPlan() }
    func drain() {} // Wait for any already queued synchronous operation before teardown.
    func proposedOffset(_ image: CGImage) throws -> Int? { try Task.checkCancellation(); return stitcher.proposedOffset(image) }
    func configureFixedEdges(_ edges: ScrollFixedEdges) throws -> Update {
        let replacement = try stitcher.reconfigured(edges: edges)
        try Task.checkCancellation()
        stitcher = replacement
        return Update(increment: nil, preview: stitcher.preview, frames: stitcher.frameCount, fixedEdges: stitcher.fixedEdges)
    }
}

@MainActor
final class ScrollCapture: ObservableObject {
    private static let automationPermissionMessage = L10n.text("自动滚动需要辅助功能权限。授权后再开启，已截内容会保留。")
    @Published private(set) var active = false
    @Published private(set) var finishing = false
    @Published private(set) var finishingOutput: ScrollCaptureOutput?
    var deliveryProgress: ScrollDeliveryProgress? {
        guard finishing, let finishingOutput else { return nil }
        return cancelExportRequested ? .cancelling : ScrollDeliveryProgress(output: finishingOutput)
    }
    @Published private(set) var height = 0
    @Published private(set) var frames = 0
    @Published private(set) var preview = ScrollPreview()
    @Published private(set) var source: ScrollCaptureSource = .region
    @Published private(set) var targetName = ""
    @Published private(set) var targetThumbnail: CGImage?
    var requiresStreamingExport: Bool {
        preview.width > 0 && preview.height > 0 && !ScrollImageCapacity.canRenderWhole(width: preview.width, height: preview.height)
    }
    @Published private(set) var warning: String?
    @Published private(set) var stopReason: ScrollCaptureStopReason?
    @Published private(set) var automatic = false
    @Published private(set) var paused = false
    @Published private(set) var needsAutomationPermission = false
    @Published private(set) var choosingFile = false
    @Published private(set) var axis: ScrollAxis = .vertical
    @Published private(set) var direction: ScrollDirection = .forward
    @Published private(set) var speed: ScrollCaptureSpeed = .standard
    @Published private(set) var needsSeamRecovery = false
    @Published private(set) var containers: [ScrollContainerCandidate] = []
    @Published private(set) var selectedContainerID: String?
    @Published private(set) var scanningContainers = false
    @Published private(set) var manualScrollPoint: CGPoint?
    @Published private(set) var suggestedFixedEdges: ScrollFixedEdges?
    @Published private(set) var fixedEdges: ScrollFixedEdges = .none
    @Published private(set) var waitingForStableFrame = false
    @Published private(set) var unstableRegions: [CGRect] = []
    @Published private(set) var stabilityThumbnail: CGImage?
    var containerSelection: CGRect {
        if source == .window, let targetWindowFrame { return targetWindowFrame }
        guard let screen else { return .zero }
        return CGRect(x: screen.frame.minX + rect.minX,
                      y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.minY - rect.maxY,
                      width: rect.width, height: rect.height)
    }
    var selectedContainer: ScrollContainerCandidate? { containers.first { $0.id == selectedContainerID } }
    var onFinish: ((CGImage, ScrollCaptureOutput) -> Void)?
    /// Runs inside the export task. Accepted tiles stay alive until the editor
    /// handoff (including its history transaction) has actually succeeded.
    var onPrepareEditor: (@MainActor (CGImage) async throws -> Void)?
    /// Production clipboard handoff must finish before accepted tiles are freed.
    var onPrepareClipboard: (@MainActor (CGImage) async throws -> Void)?
    var onStreamExport: ((URL) -> Void)?
    // Diagnostics can independently measure the accepted source before another
    // wheel event. Production sessions leave this observer unset.
    var onDiagnosticAcceptedFrame: ((CGImage, Int) async throws -> Bool)?
    private(set) var initialFrameSamples = 0
    private var exportTask: Task<ScrollExportResult, Error>?
    @Published private(set) var cancelExportRequested = false
    // Invoked synchronously before macOS opens its permission UI.
    var onAutomationPermissionPresentation: ((Bool) -> Void)?
    private(set) var presentingAutomationPermission = false
    private var task: Task<Void, Never>?
    // Exclusive user operations (initialization, undo, fixed-edge rebuild, teardown).
    // Background polling must not pulse the entire HUD's enabled state.
    @Published private(set) var processingSegment = false
    private var worker: ScrollCaptureWorker?
    private var session = 0
    private var cancelling = false
    private let engine = CaptureEngine()
    private var screen: NSScreen?
    private var captureTopology: DesktopTopology?
    var backingScale: CGFloat { source == .window ? windowPixelScale : screen?.backingScaleFactor ?? 1 }
    private var windowPixelScale: CGFloat = 1
    private var windowRasterSize: CGSize?
    var targetWindowGeometry: (id: CGWindowID, frame: CGRect)? {
        guard let id = targetWindowID, let frame = targetWindowFrame else { return nil }
        return (id, frame)
    }
    private var rect: CGRect = .zero
    private var content: SCShareableContent?
    private let scanContainers: @Sendable (pid_t, CGRect) -> ScrollContainerScan
    private let isAutomationTrusted: () -> Bool
    private let requestAutomationPermission: () -> Void
    private var targetWindowID: CGWindowID?
    private var referenceWindow: SCWindow?
    private var targetWindowFrame: CGRect?
    private var targetProcessID: pid_t?
    private var pausedBeforeFileSelection = false
    private var generation = 0
    private var progress = ScrollCaptureProgress()
    private var skipNextAutomaticScroll = false
    private var responseGate = ScrollResponseGate()
    private var pendingShortStop = false
    private var confirmingBoundary = false
    private var lastScrollPoint: CGPoint?
    private var targetActivationDeadline: TimeInterval?

    init(preview: ScrollPreview = ScrollPreview(), stitcher: ScrollStitcher? = nil,
         scanContainers: @escaping @Sendable (pid_t, CGRect) -> ScrollContainerScan = { ScrollContainerDetector.scan(pid: $0, selection: $1) },
         isAutomationTrusted: @escaping () -> Bool = { ScrollAutomationAvailability.enabled && AXIsProcessTrusted() },
         requestAutomationPermission: @escaping () -> Void = {
             guard ScrollAutomationAvailability.enabled else { return }
             _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
         }) {
        self.scanContainers = scanContainers
        self.isAutomationTrusted = isAutomationTrusted; self.requestAutomationPermission = requestAutomationPermission
        self.worker = stitcher.map { ScrollCaptureWorker($0) }
        self.axis = stitcher?.axis ?? .vertical
        self.direction = stitcher?.direction ?? .forward
        self.preview = stitcher?.preview ?? preview
        height = self.preview.height; frames = self.preview.tiles.filter { $0.id > 0 }.count; active = stitcher != nil
    }

    @discardableResult
    func setAutomatic(_ enabled: Bool, requestPermission: Bool = true) -> Bool {
        let enabled = enabled && ScrollAutomationAvailability.enabled
        guard !finishing, !choosingFile, !processingSegment else { return false }
        if enabled && !isAutomationTrusted() {
            automatic = false; needsAutomationPermission = true
            warning = Self.automationPermissionMessage
            if requestPermission {
                paused = true; generation += 1
                presentingAutomationPermission = true
                onAutomationPermissionPresentation?(true)
                requestAutomationPermission()
            }
            return false
        }
        if enabled, targetWindowID != nil, selectedContainer == nil, manualScrollPoint == nil {
            // Some web views and editors do not publish AXScrollArea. Deliver
            // at the selected content's center, still verifying the original
            // window owns the point and the full capture area is visible.
            manualScrollPoint = CGPoint(x: containerSelection.midX, y: containerSelection.midY)
        }
        if paused || automatic != enabled {
            skipNextAutomaticScroll = progress.awaitingResponse
            progress.resumeAtCurrentPosition(); responseGate = ScrollResponseGate()
        }
        let returningFromPermission = presentingAutomationPermission
        presentingAutomationPermission = false
        onAutomationPermissionPresentation?(false)
        automatic = enabled; needsAutomationPermission = false; warning = nil; stopReason = nil; confirmingBoundary = false; paused = false; generation += 1
        targetActivationDeadline = nil
        if enabled || returningFromPermission { restoreTargetFocus() }
        return true
    }

    private func restoreTargetFocus() {
        guard let targetProcessID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcessID else { return }
        // Activation is asynchronous. Do not deliver another wheel or acquire a
        // segment until the selected application's focus has actually returned.
        guard NSRunningApplication(processIdentifier: targetProcessID)?.activate(options: []) == true else {
            paused = true; warning = L10n.text("无法返回原窗口，已暂停。请点击原窗口后继续，已有片段保留。")
            return
        }
        targetActivationDeadline = ProcessInfo.processInfo.systemUptime + 1
    }

    func selectContainer(_ id: String) {
        guard active, !finishing, !choosingFile, !processingSegment,
              containers.contains(where: { $0.id == id }) else { return }
        selectedContainerID = id; manualScrollPoint = nil
        paused = true; generation += 1; stopReason = nil; confirmingBoundary = false
        warning = L10n.text("滚动目标已更新。确认预览后继续，已有片段保留。")
    }
    func configureFixedEdges(_ edges: ScrollFixedEdges) async {
        guard active, !finishing, !choosingFile, !processingSegment, let worker else { return }
        paused = true; generation += 1; processingSegment = true
        let stamp = session
        task?.cancel(); await task?.value; task = nil
        do {
            let result = try await worker.configureFixedEdges(edges)
            guard active, session == stamp else { return }
            preview = result.preview; height = preview.height; frames = result.frames
            fixedEdges = edges; suggestedFixedEdges = nil; needsSeamRecovery = false
            skipNextAutomaticScroll = true
            progress.resumeAtCurrentPosition(); responseGate = ScrollResponseGate(); pendingShortStop = false
            paused = false; warning = nil; stopReason = nil; confirmingBoundary = false; restoreTargetFocus()
        } catch { if active, session == stamp { warning = L10n.text("固定栏设置未完成：\(error.localizedDescription) 原结果已保留。") } }
        if active, session == stamp { processingSegment = false; beginPolling() }
    }

    func setManualScrollPoint(x: Double, y: Double) {
        guard active, !finishing, !choosingFile, !processingSegment,
              x.isFinite, y.isFinite, (0.05...0.95).contains(x), (0.05...0.95).contains(y) else { return }
        let selection = containerSelection
        manualScrollPoint = CGPoint(x: selection.minX + selection.width * x, y: selection.minY + selection.height * y)
        selectedContainerID = nil; paused = true; generation += 1; stopReason = nil; confirmingBoundary = false
        warning = L10n.text("滚动点已指定。确认它位于正文容器内再开启自动滚动；已有片段保留。")
    }

    func refreshContainers() async {
        guard ScrollAutomationAvailability.enabled, active, !finishing, !choosingFile, !processingSegment, !scanningContainers,
              let pid = targetProcessID else { return }
        paused = true; generation += 1; scanningContainers = true
        let stamp = session, revision = generation, selection = containerSelection
        let detector = self.scanContainers
        let scan = await Task.detached(priority: .userInitiated) { detector(pid, selection) }.value
        guard active, session == stamp else { return }
        scanningContainers = false
        guard generation == revision else { return }
        containers = scan.candidates
        if let id = selectedContainerID, !containers.contains(where: { $0.id == id }) { selectedContainerID = nil }
        if selectedContainerID == nil, manualScrollPoint == nil {
            selectedContainerID = ScrollContainerDetector.preferred(containers, selection: selection)?.id
        }
        warning = containers.isEmpty ? L10n.text("没有识别到可滚动容器，可修正滚动点或手动继续。") : L10n.text("滚动区域已刷新。确认预览后继续。")
    }

    func openAutomationSettings() {
        guard ScrollAutomationAvailability.enabled else { return }
        paused = true; generation += 1
        presentingAutomationPermission = true
        onAutomationPermissionPresentation?(true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setSpeed(_ speed: ScrollCaptureSpeed) {
        guard !finishing, !choosingFile, !processingSegment else { return }
        self.speed = speed
        // A speed change must not bypass an unresolved seam.
        generation += 1
    }

    func continueManually() {
        guard setAutomatic(false) else { return }
        restoreTargetFocus()
        guard !paused else { return }
        warning = needsSeamRecovery
            ? L10n.text("已切换手动。\(direction.recoveryTitle(axis: axis))回滚一点，再慢速\(direction.movementTitle(axis: axis))滚动找回接缝；已截内容保留。")
            : L10n.text("已切换手动，慢速滚动原窗口即可继续。")
    }

    func togglePause() {
        guard active, !finishing, !choosingFile, !processingSegment else { return }
        if presentingAutomationPermission {
            // Explicit Resume returns to the target and manual capture. The
            // user can enable automation again after granting permission.
            _ = setAutomatic(false)
            return
        }
        paused.toggle(); generation += 1
        targetActivationDeadline = nil
        if !paused {
            skipNextAutomaticScroll = progress.awaitingResponse
            progress.resumeAtCurrentPosition(); responseGate = ScrollResponseGate()
            warning = nil; stopReason = nil; confirmingBoundary = false; restoreTargetFocus()
        }
    }
    func removeLastSegment() async {
        guard active, !finishing, !choosingFile, !processingSegment, frames > 1, let worker else { return }
        processingSegment = true
        let currentSession = session
        paused = true; generation += 1
        task?.cancel(); await task?.value; task = nil
        do {
            let update = try await worker.removeLast()
            guard session == currentSession, active else { return }
            height = update.preview.height; frames = update.frames; preview = update.preview
            automatic = false
            warning = L10n.text("末段已撤回。将页面\(direction.recoveryTitle(axis: axis))滚到上一段，再慢速\(direction.movementTitle(axis: axis))滚动并继续捕获。")
        } catch {
            guard session == currentSession, active else { return }
            warning = error.localizedDescription
        }
        processingSegment = false
        beginPolling()
    }

    @discardableResult
    func beginFileSelection() -> Bool {
        guard active, !finishing, !choosingFile, !processingSegment else { return false }
        pausedBeforeFileSelection = paused; paused = true; choosingFile = true; generation += 1
        return true
    }

    func completeFileSelection(_ url: URL?) async {
        guard choosingFile else { return }
        choosingFile = false
        guard let url else {
            paused = pausedBeforeFileSelection; generation += 1
            if !paused { restoreTargetFocus() }
            return
        }
        await finish(output: .file(url))
    }
    func completeSegmentSelection(_ url: URL?) async {
        guard choosingFile else { return }
        choosingFile = false
        guard let url else {
            paused = pausedBeforeFileSelection; generation += 1
            if !paused { restoreTargetFocus() }
            return
        }
        await finish(output: .segments(url))
    }

    func start(screen: NSScreen, rect: CGRect, content: SCShareableContent, automatic: Bool,
               axis: ScrollAxis = .vertical, direction: ScrollDirection = .forward, targetWindowID requestedWindowID: CGWindowID? = nil,
               source: ScrollCaptureSource = .region) async throws {
        guard !active, !cancelling else { return }
        session += 1
        let currentSession = session
        // Selection overlays and focus changes invalidate the earlier inventory.
        let content = try await engine.content()
        guard session == currentSession, !cancelling else { throw CancellationError() }
        try Task.checkCancellation()
        let topology = DesktopTopology.current()
        let display = try topology.display(for: screen)
        if source == .region { _ = try display.sourceRect(rect) }
        captureTopology = topology
        self.axis = axis; self.direction = direction; self.source = source
        windowRasterSize = nil; windowPixelScale = screen.backingScaleFactor
        targetThumbnail = nil
        self.screen = screen; self.rect = rect; self.content = content
        let point = CGPoint(x: screen.frame.minX + rect.midX,
                            y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.minY - rect.midY)
        let windowIDs = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let ranks = Dictionary(uniqueKeysWithValues: windowIDs.enumerated().map { ($0.element, $0.offset) })
        let targetWindow = content.windows.filter {
            $0.windowLayer == 0 && ranks[$0.windowID] != nil &&
            (requestedWindowID == nil || $0.windowID == requestedWindowID) &&
            (source == .window ? requestedWindowID != nil : $0.frame.contains(point)) &&
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.min { (ranks[$0.windowID] ?? Int.max) < (ranks[$1.windowID] ?? Int.max) }
        targetProcessID = targetWindow?.owningApplication?.processID
        targetWindowID = targetWindow?.windowID
        referenceWindow = targetWindow
        // Use the same exact-ID geometry query at startup and during polling.
        targetWindowFrame = targetWindowID.flatMap { CaptureWindowInfo.read($0)?.frame }
        targetName = targetWindow?.owningApplication?.applicationName ?? L10n.text("所选窗口")
        if source == .window, let targetWindow, let targetWindowFrame {
            self.rect = ScrollWindowGeometry.localRect(targetWindowFrame, screenFrame: screen.frame,
                desktopTop: NSScreen.screens.first?.frame.maxY ?? 0)
            windowPixelScale = CGFloat(SCContentFilter(desktopIndependentWindow: targetWindow).pointPixelScale)
        }
        let preparation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return ScrollCaptureWorker(try ScrollStitcher(axis: axis, direction: direction))
        }
        let worker = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        guard session == currentSession, !cancelling else { throw CancellationError() }
        try Task.checkCancellation()
        self.worker = worker
        height = 0; frames = 0; warning = nil; paused = false; stopReason = nil; confirmingBoundary = false; lastScrollPoint = nil
        progress = ScrollCaptureProgress(); needsSeamRecovery = false
        responseGate = ScrollResponseGate(); pendingShortStop = false; targetActivationDeadline = nil
        waitingForStableFrame = false; unstableRegions = []; stabilityThumbnail = nil
        skipNextAutomaticScroll = false
        preview = ScrollPreview(axis: axis, direction: direction)
        active = true; finishing = false; processingSegment = true
        containers = []; selectedContainerID = nil; manualScrollPoint = nil; scanningContainers = false
        suggestedFixedEdges = nil; fixedEdges = .none
        initialFrameSamples = 0
        do {
            guard let targetWindow else { throw CaptureError.message(L10n.text("刚选中的网页或文档已移动、关闭，或被切换到了其他桌面。请恢复页面后重新框选。")) }
            guard targetWindowFrame != nil else { throw CaptureError.message(L10n.text("系统暂时无法读取这个页面的位置。请将它恢复到屏幕上后重新框选。")) }
            restoreTargetFocus()
            if source == .window, isAutomationTrusted(), let pid = targetProcessID, let frame = targetWindowFrame {
                let raise = Task.detached(priority: .userInitiated) { ScrollWindowGeometry.raise(pid: pid, frame: frame) }
                await withTaskCancellationHandler { await raise.value } onCancel: { raise.cancel() }
                try Task.checkCancellation()
                guard session == currentSession, active else { throw CancellationError() }
            }
            // Wait for activation before comparing display and window pixels.
            // Inactive translucent windows can render differently during reentry.
            if let deadline = targetActivationDeadline {
                while NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcessID,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                    guard session == currentSession, active else { throw CancellationError() }
                }
                targetActivationDeadline = nil
            }
            let settled = try await ScrollInitialFrame.acquire {
                try self.captureTopology?.requireUnchanged()
                let image = try await self.captureFrame(rect, screen: screen, content: content, target: targetWindow) {
                    guard self.session==currentSession,self.active else { throw CancellationError() }
                }
                try self.captureTopology?.requireUnchanged()
                guard self.session == currentSession, self.active else { throw CancellationError() }
                return image
            }
            guard session == currentSession, active else { throw CancellationError() }
            try captureTopology?.requireUnchanged()
            let initial = settled.image
            if source == .window { windowRasterSize = CGSize(width: initial.width, height: initial.height) }
            initialFrameSamples = settled.samples
            let update = try await worker.append(initial)
            if let observer = onDiagnosticAcceptedFrame { _ = try await observer(initial, update.frames) }
            guard session == currentSession, active else { throw CancellationError() }
            try captureTopology?.requireUnchanged()
            height = update.preview.height; frames = update.frames; preview = update.preview; targetThumbnail = update.targetThumbnail
            if isAutomationTrusted(), let pid = targetProcessID {
                scanningContainers = true
                let selection = containerSelection
                let detector = self.scanContainers
                let scan = await Task.detached(priority: .userInitiated) { detector(pid, selection) }.value
                guard session == currentSession, active else { throw CancellationError() }
                containers = scan.candidates
                selectedContainerID = ScrollContainerDetector.preferred(containers, selection: selection)?.id
                scanningContainers = false
            }
            processingSegment = false
        } catch {
            if session == currentSession {
                active = false; self.worker = nil; preview = ScrollPreview(); processingSegment = false
            }
            throw error
        }
        // If automation is not authorized, preserve the selection and initial
        // image while permission UI is open. The HUD can resume manual capture.
        setAutomatic(automatic)
        beginPolling()
    }

    private func captureFrame(_ rect: CGRect, screen: NSScreen, content: SCShareableContent, target: SCWindow,
                              validate: @MainActor () throws -> Void) async throws -> CGImage {
        if source == .region { return try await engine.visibleRegion(rect, screen: screen, content: content, target: target, validate: validate) }
        // Only window pixels are acquired; screen placement and other windows
        // cannot enter the result. Input delivery still proves the window owns
        // its delivery point before each wheel command.
        try validate()
        guard let current = CaptureWindowInfo.read(target.windowID), current.processID == targetProcessID,
              current.isOnScreen != false, let expected = targetWindowFrame,
              ScrollWindowGeometry.sizeMatches(expected, current.frame) else {
            throw CaptureError.message(L10n.text("所选窗口已关闭、隐藏或改变大小，已截内容保留。恢复窗口后可继续。"))
        }
        let image = try await engine.scrollingWindow(target, validate: validate)
        guard let after = CaptureWindowInfo.read(target.windowID), after.processID == current.processID,
              after.isOnScreen != false, ScrollWindowGeometry.sizeMatches(current.frame, after.frame) else {
            throw CaptureError.message(L10n.text("窗口在取图时改变了大小或状态，已暂停并保留长图。"))
        }
        if let size = windowRasterSize, size != CGSize(width: image.width, height: image.height) {
            throw CaptureError.message(L10n.text("窗口的显示比例已改变，已截内容保留。请先保存，再重新开始窗口长图。"))
        }
        return image
    }

    static func unobscuredScrollPoint(rect: CGRect, screenFrame: CGRect, desktopTop: CGFloat,
                                     target: CGWindowID, avoiding: [CGRect] = []) -> CGPoint? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return unobscuredScrollPoint(rect: rect, screenFrame: screenFrame, desktopTop: desktopTop, target: target, windows: windows, avoiding: avoiding)
    }
    static func unobscuredScrollPoint(rect: CGRect, screenFrame: CGRect, desktopTop: CGFloat,
                                     target: CGWindowID, windows: [[String: Any]], avoiding: [CGRect] = []) -> CGPoint? {
        for fraction in ScrollDeliveryPoints.fractions {
            let point = CGPoint(x: screenFrame.minX + rect.minX + rect.width * fraction.x,
                                y: desktopTop - screenFrame.minY - rect.minY - rect.height * fraction.y)
            if avoiding.contains(where: { $0.contains(point) }) { continue }
            let first = windows.first { item in
                guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return frame.contains(point)
            }
            if first?[kCGWindowNumber as String] as? UInt32 == target { return point }
        }
        return nil
    }
    static func targetUnchanged(_ expected: CGRect, _ current: CGRect) -> Bool {
        abs(expected.minX - current.minX) <= 1 && abs(expected.minY - current.minY) <= 1
        && abs(expected.width - current.width) <= 1 && abs(expected.height - current.height) <= 1
    }
    private func beginPolling() {
        guard let screen, let content else { return }
        let rect = self.rect, pollingSession = self.session
        task = Task { [weak self] in
            var lastGeneration = self?.generation ?? 0
            var stabilityGate = ScrollStabilityGate()
            while !Task.isCancelled {
                guard let self, self.active else { return }
                let iterationGeneration = self.generation
                do {
                    if lastGeneration != self.generation { self.progress.resetCounters(); lastGeneration = self.generation; stabilityGate = ScrollStabilityGate(); self.waitingForStableFrame = false }
                    if self.paused { try await Task.sleep(for: .milliseconds(200)); continue }
                    if let deadline = self.targetActivationDeadline {
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == self.targetProcessID {
                            self.targetActivationDeadline = nil
                        } else if ProcessInfo.processInfo.systemUptime < deadline {
                            try await Task.sleep(for: .milliseconds(50)); continue
                        } else {
                            self.targetActivationDeadline = nil; self.paused = true; self.waitingForStableFrame = false
                            self.warning = L10n.text("原窗口尚未获得焦点，已暂停。请点击原窗口后继续，已有片段保留。")
                            continue
                        }
                    }
                    try self.captureTopology?.requireUnchanged()
                    if let id = self.targetWindowID, let expected = self.targetWindowFrame {
                        var current = CaptureWindowInfo.read(id)
                        if current == nil {
                            // Do not call a transient WindowServer lookup failure a closed window.
                            try await Task.sleep(for: .milliseconds(120))
                            guard !Task.isCancelled, self.active, self.session == pollingSession else { return }
                            if self.paused { continue }
                            current = CaptureWindowInfo.read(id)
                        }
                        guard let current, current.processID == self.targetProcessID else {
                            self.paused = true; self.warning = L10n.text("暂时无法读取原目标窗口，已暂停。请恢复原窗口后继续，已截内容保留。"); continue
                        }
                        guard current.isOnScreen != false else {
                            self.paused = true; self.warning = L10n.text("原目标窗口已隐藏或最小化，已暂停。恢复窗口后可继续，已截内容保留。"); continue
                        }
                        if self.source == .window, ScrollWindowGeometry.sizeMatches(expected, current.frame),
                           !Self.targetUnchanged(expected, current.frame) {
                            let dx = current.frame.minX - expected.minX, dy = current.frame.minY - expected.minY
                            self.targetWindowFrame = current.frame
                            self.containers = self.containers.map {
                                ScrollContainerCandidate(id: $0.id, frame: $0.frame.offsetBy(dx: dx, dy: dy), depth: $0.depth)
                            }
                            if let point = self.manualScrollPoint { self.manualScrollPoint = CGPoint(x: point.x + dx, y: point.y + dy) }
                            // Re-identify AX areas after translation; their stable
                            // geometric IDs refer to their actual screen frame.
                            if let selected = self.selectedContainer {
                                let area = selected.frame.intersection(self.containerSelection)
                                self.selectedContainerID = nil
                                self.manualScrollPoint = CGPoint(x: area.midX, y: area.midY)
                            }
                        } else if !Self.targetUnchanged(expected, current.frame) {
                            let sizeChanged = abs(expected.width - current.frame.width) > 1 || abs(expected.height - current.frame.height) > 1
                            self.paused = true
                            self.warning = sizeChanged
                                ? L10n.text("原目标窗口尺寸已改变，已暂停。恢复原尺寸后可继续，已截内容保留。")
                                : L10n.text("原目标窗口位置已改变，已暂停。恢复原位置后可继续，已截内容保留。")
                            continue
                        }
                    }
                    if self.automatic {
                        guard self.isAutomationTrusted() else {
                            self.setAutomatic(true, requestPermission: false)
                            continue
                        }
                        // Check obstruction while waiting for a seam as well;
                        // a foreground cover must stop reads, not just wheels.
                        do {
                            let revision = self.generation
                            if let selected = self.selectedContainer, let pid = self.targetProcessID {
                                let selection = self.containerSelection
                                let detector = self.scanContainers
                                let scan = await Task.detached(priority: .userInitiated) { detector(pid, selection) }.value
                                guard !Task.isCancelled, self.active else { return }
                                if self.paused || self.generation != revision { continue }
                                guard scan.candidates.contains(where: { $0.id == selected.id }) else {
                                    self.paused = true; self.warning = L10n.text("滚动容器已改变或无法确认，已暂停。刷新区域或改为手动继续。"); continue
                                }
                                self.containers = scan.candidates
                            }
                            let deliveryWorld: CGRect
                            var excluded: [CGRect] = []
                            if let selected = self.selectedContainer,
                               let area = ScrollContainerDetector.pointRect(selected, selection: self.containerSelection) {
                                deliveryWorld = area
                                excluded = self.containers.filter { $0.id != selected.id && selected.frame.contains($0.frame) }.map(\.frame)
                            } else if let point = self.manualScrollPoint {
                                deliveryWorld = CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1)
                            } else {
                                self.paused = true; self.warning = L10n.text("请选择滚动容器或修正滚动点，也可改为手动继续。"); continue
                            }
                            let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
                            let deliveryRect = CGRect(x: deliveryWorld.minX - screen.frame.minX,
                                                      y: desktopTop - screen.frame.minY - deliveryWorld.maxY,
                                                      width: deliveryWorld.width, height: deliveryWorld.height)
                            let event = ScrollAutomationEvent.make(rect: deliveryRect, screenFrame: screen.frame,
                                                                   desktopTop: NSScreen.screens.first?.frame.maxY ?? 0, axis: self.axis, speed: self.confirmingBoundary ? .slow : self.speed, direction: self.direction, targetWindowID: self.targetWindowID)
                            // Direct process delivery leaves freshly created scroll
                            // events without an AppKit window. Let WindowServer
                            // annotate them, only at an unobscured point belonging
                            // to the originally selected window.
                            guard let event, let id = self.targetWindowID else { self.paused = true; continue }
                            var location = Self.unobscuredScrollPoint(rect: deliveryRect, screenFrame: screen.frame,
                                                                      desktopTop: desktopTop, target: id, avoiding: excluded)
                            if location == nil, let pid = self.targetProcessID, let frame = self.targetWindowFrame {
                                guard let reference = self.referenceWindow else { throw CaptureError.message(L10n.text("目标窗口已失效，请重新选择。")) }
                                _ = try await self.captureFrame(rect, screen: screen, content: content, target: reference) {
                                    guard self.active, self.session == pollingSession else { throw CancellationError() }
                                    guard !self.paused, self.generation == revision else { throw ScrollVisibleFrame.Obsolete() }
                                }
                                guard !Task.isCancelled, self.active else { return }
                                if self.paused || self.generation != revision { continue }
                                let area = deliveryWorld, avoid = excluded, displayVerified = self.source == .region
                                location = await Task.detached(priority: .userInitiated) {
                                    ScrollContainerDetector.globalTargetPoint(area: area, avoiding: avoid, pid: pid, windowID: id, windowFrame: frame,
                                                                             displayPixelsVerified: displayVerified)
                                }.value
                                guard !Task.isCancelled, self.active else { return }
                                if self.paused || self.generation != revision { continue }
                            }
                            guard let location else {
                                self.paused = true
                                self.warning = L10n.text("目标滚动区域被遮挡，已暂停。移开遮挡窗口后可继续，已捕获内容保留。")
                                continue
                            }
                            if self.progress.shouldScroll && !self.skipNextAutomaticScroll {
                                try self.captureTopology?.requireUnchanged()
                                event.location = location
                                event.post(tap: .cgSessionEventTap)
                                self.progress.didScroll(); self.lastScrollPoint = location
                                let length = self.axis == .vertical ? deliveryRect.height : deliveryRect.width
                                self.responseGate.didScroll(expectedPixels: Int((Double((self.confirmingBoundary ? ScrollCaptureSpeed.slow : self.speed).step(for: length)) * self.backingScale).rounded()))
                            }
                        }
                    }
                    self.skipNextAutomaticScroll = false
                    try await Task.sleep(for: .milliseconds(self.automatic ? self.speed.delayMilliseconds : 60))
                    if self.paused { continue }
                    let captureRevision = self.generation
                    try self.captureTopology?.requireUnchanged()
                    guard let referenceWindow=self.referenceWindow else { throw CaptureError.message(L10n.text("目标窗口已失效，请重新选择。")) }
                    let image = try await self.captureFrame(rect, screen: screen, content: content, target: referenceWindow) {
                        guard self.active,self.session==pollingSession else { throw CancellationError() }
                        guard !self.paused,self.generation==captureRevision else { throw ScrollVisibleFrame.Obsolete() }
                    }
                    try self.captureTopology?.requireUnchanged()
                    guard !Task.isCancelled, let worker = self.worker else { return }
                    if self.paused || captureRevision != self.generation { continue }
                    let automaticSample = self.automatic, sampleAxis = self.axis, sampleDirection = self.direction
                    try await Task.sleep(for: .milliseconds(automaticSample ? 180 : 40))
                    let confirmed = try await self.captureFrame(rect, screen: screen, content: content, target: referenceWindow) {
                        guard self.active,self.session==pollingSession else { throw CancellationError() }
                        guard !self.paused,self.generation==captureRevision else { throw ScrollVisibleFrame.Obsolete() }
                    }
                    try self.captureTopology?.requireUnchanged()
                    guard !Task.isCancelled else { return }
                    if self.paused || captureRevision != self.generation { continue }
                    let stability = await Task.detached(priority: .userInitiated) {
                        automaticSample ? ScrollFrameStability.compare(image, confirmed)
                            : ScrollFrameStability.compareManual(image, confirmed, axis: sampleAxis, direction: sampleDirection)
                    }.value
                    guard !Task.isCancelled else { return }
                    if self.paused || captureRevision != self.generation { continue }
                    self.unstableRegions = stability.regions
                    self.stabilityThumbnail = stability.thumbnail
                    let stabilityDecision = stabilityGate.evaluate(stable: stability.stable, now: ProcessInfo.processInfo.systemUptime)
                    self.waitingForStableFrame = stabilityDecision == .wait
                    if stabilityDecision != .accept {
                        self.skipNextAutomaticScroll = true
                        self.warning = self.automatic ? L10n.text("页面仍在变化，保持当前位置等待稳定…") : L10n.text("画面尚未稳定，请停止滚动，等待当前位置加载完成…")
                        if stabilityDecision == .pause {
                            self.paused = true
                            self.warning = L10n.text("页面持续变化，已暂停。已截片段保留；停止动画或等待加载完成后继续。")
                        }
                        continue
                    }
                    if self.automatic && self.progress.awaitingResponse {
                        let offset = try await worker.proposedOffset(confirmed)
                        guard !Task.isCancelled else { return }
                        if self.paused || captureRevision != self.generation { continue }
                        switch self.responseGate.evaluate(offset: offset) {
                        case .wait:
                            self.waitingForStableFrame = true; self.warning = L10n.text("滚动仍未达到请求位置，保留重叠并等待…")
                            continue
                        case .acceptAndPause: self.pendingShortStop = true
                        case .accept: break
                        }
                    }
                    // The worker serializes frame commits. Pause/speed/selection changes
                    // invalidate further sampling, not an already committed source frame.
                    // Destructive operations and export cancel and await this polling task
                    // before touching the worker, so the accepted snapshot is applied first.
                    let update = try await worker.append(confirmed)
                    guard self.active, self.session == pollingSession else { return }
                    let increment = update.increment
                    self.targetThumbnail = update.targetThumbnail
                    if let increment, increment > 0 {
                        self.height = update.preview.height; self.frames = update.frames
                        self.preview = update.preview
                        self.fixedEdges = update.fixedEdges
                    }
                    guard !Task.isCancelled else { return }
                    if self.paused || self.finishing || self.choosingFile || captureRevision != self.generation { continue }
                    var diagnosticPause = false
                    if let increment, increment > 0, let observer = self.onDiagnosticAcceptedFrame {
                        diagnosticPause = try await observer(confirmed, update.frames)
                    }
                    guard !Task.isCancelled else { return }
                    if self.paused || self.finishing || self.choosingFile || captureRevision != self.generation { continue }
                    self.suggestedFixedEdges = update.suggestedFixedEdges
                    if update.suggestedFixedEdges != nil {
                        self.paused = true
                        self.warning = L10n.text("顶部或底部内容保持不动，但也可能是重复正文。请选择如何保留，选择后会继续捕获。")
                        continue
                    }
                    self.progress.observe(increment)
                    if diagnosticPause { self.paused = true; continue }
                    if let increment, increment > 0 {
                        self.stopReason = nil
                        // Keep a valid short seam and send the next wheel slowly.
                        // Near the end this allows the last few rows to be accepted;
                        // small application-specific steps are not themselves errors.
                        self.confirmingBoundary = self.pendingShortStop
                        self.pendingShortStop = false
                    }
                    self.needsSeamRecovery = self.progress.needsSeamRecovery
                    if increment == nil {
                        self.warning = L10n.text("未找到可靠接缝。请\(self.direction.recoveryTitle(axis: self.axis))回滚一点，再慢速\(self.direction.movementTitle(axis: self.axis))滚动；避开固定栏与动态区域。")
                        if self.automatic {
                            self.speed = .slow
                            // Retry at the current position while lazy loading
                            // or scroll transitions settle; don't scroll farther
                            // and lose the remaining overlap.
                            if self.progress.failures < 3 { self.warning = L10n.text("已降为慢速，等待页面稳定，在原位置重试…") }
                            else { self.paused = true }
                        } else if self.progress.failures >= 3 {
                            self.paused = true
                        }
                    } else {
                        self.warning = self.needsAutomationPermission ? Self.automationPermissionMessage : nil
                        if self.automatic && self.progress.awaitingResponse && self.progress.unchanged >= 6 {
                            let revision = self.generation
                            let pid = self.targetProcessID, point = self.lastScrollPoint, frame = self.targetWindowFrame
                            let selectedFrame = self.selectedContainer?.frame, axis = self.axis, direction = self.direction
                            let reader = Task.detached(priority: .userInitiated) { () -> ScrollPositionEvidence? in
                                guard let pid, let point, let frame, !Task.isCancelled else { return nil }
                                let first = ScrollContainerDetector.position(pid: pid, point: point, windowFrame: frame,
                                                                            selectedFrame: selectedFrame, axis: axis)
                                // A loading page can move its scrollbar boundary. Require
                                // a second unchanged reading before labeling that boundary.
                                guard let first, first.atBoundary(direction: direction) else { return first }
                                try? await Task.sleep(for: .milliseconds(200))
                                guard !Task.isCancelled,
                                      let second = ScrollContainerDetector.position(pid: pid, point: point, windowFrame: frame,
                                                                                   selectedFrame: selectedFrame, axis: axis), second == first else { return nil }
                                return second
                            }
                            let evidence = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
                            guard !Task.isCancelled, self.active, self.session == pollingSession else { return }
                            guard !self.paused, self.generation == revision else { continue }
                            self.paused = true; self.waitingForStableFrame = false
                            let reason = ScrollCaptureStopReason.stationary(evidence: evidence, direction: direction)
                            if reason == .boundary {
                                self.stopReason = .boundary
                                let edge = axis == .vertical ? (direction == .forward ? L10n.text("底部") : L10n.text("顶部")) : (direction == .forward ? L10n.text("右端") : L10n.text("左端"))
                                self.warning = L10n.text("已到当前滚动区域\(edge)，已截内容保留。可完成编辑；页面加载新内容后也可继续。")
                            } else if reason == .unresponsive {
                                self.stopReason = .unresponsive
                                self.warning = L10n.text("目标没有响应滚动。请选择页面正文，或改为手动滚动；已有画面保留。")
                            } else {
                                self.stopReason = .unconfirmed
                                self.warning = L10n.text("画面未再滚动，暂时无法确认是否到达边界。可完成当前结果，或选择正文后继续；已有片段保留。")
                            }
                        }
                    }
                } catch is ScrollVisibleFrame.Obsolete { continue }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self.active, self.session == pollingSession else { return }
                    guard self.generation == iterationGeneration else { continue }
                    self.paused = true; self.waitingForStableFrame = false
                    self.warning = error.localizedDescription
                    // Keep the loop alive so Resume can retry a transient failure.
                }
            }
        }
    }
    func finish(output: ScrollCaptureOutput = .clipboard) async {
        guard active, !finishing, !choosingFile, !processingSegment else { return }
        finishingOutput = output; cancelExportRequested = false; finishing = true
        task?.cancel(); await task?.value; task = nil
        defer { exportTask = nil; finishingOutput = nil; cancelExportRequested = false }
        do {
            guard !cancelExportRequested else { throw CancellationError() }
            guard let worker else { throw CaptureError.message(L10n.text("长图数据已失效。")) }
            let prepareEditor = onPrepareEditor
            let prepareClipboard = onPrepareClipboard
            let job = Task.detached(priority: .userInitiated) { () throws -> ScrollExportResult in
                let plan = try await worker.exportPlan()
                switch output {
                case .clipboard:
                    let image = try await worker.render(); try Task.checkCancellation()
                    if let prepareClipboard {
                        try await prepareClipboard(image)
                        // A successful pasteboard write has committed, even if
                        // cancellation arrives just after the synchronous write.
                    }
                    return .image(image)
                case .editor:
                    let image = try await worker.render(); try Task.checkCancellation()
                    guard let prepareEditor else { throw CaptureError.message(L10n.text("编辑器暂时无法打开，长图仍保留，可保存或复制。")) }
                    try await prepareEditor(image)
                    // The history commit is the handoff boundary. A late
                    // cancellation must not relabel a committed result as lost.
                    return .image(image)
                case .segments(let url):
                    try plan.exportSegments(to: url); return .file(url)
                case .file(let url):
                    if url.pathExtension.lowercased() == "pdf" {
                        // Preserve normal-size history without a post-commit
                        // cancellable render. Oversized PDFs need no whole bitmap.
                        let image = plan.canRenderWhole ? try await worker.render() : nil
                        try plan.exportPDF(to: url)
                        if let image { return .image(image) }
                        return .file(url)
                    }
                    let image = try await worker.render()
                    try CaptureImageExport.png(image, to: url); return .image(image)
                }
            }
            exportTask = job
            let result = try await job.value
            if case .clipboard = output, prepareClipboard == nil, job.isCancelled { throw CancellationError() }
            active = false; finishing = false; self.worker = nil; preview = ScrollPreview()
            switch result {
            case .image(let image): onFinish?(image, output)
            case .file(let url): onStreamExport?(url)
            }
        } catch {
            finishing = false; paused = true
            if case .editor = output {
                warning = error is CancellationError ? L10n.text("已取消完成操作，长图仍保留，可继续捕获、保存或复制。")
                    : L10n.text("未能打开编辑器：\(error.localizedDescription) 长图仍保留，可重试、保存或复制。")
            } else if case .clipboard = output {
                warning = error is CancellationError ? L10n.text("已取消复制，长图仍保留，可继续捕获、保存或复制。")
                    : L10n.text("复制未完成：\(error.localizedDescription) 长图仍保留，可重试或保存。")
            } else {
                warning = error is CancellationError ? L10n.text("导出已取消，原目标与捕获片段保留，可重新导出。") : L10n.text("保存未完成：\(error.localizedDescription) 可重新保存或复制。")
            }
            beginPolling()
        }
    }
    func cancel() async {
        if finishing { cancelExportRequested = true; exportTask?.cancel(); return }
        guard !finishing, !choosingFile, !cancelling else { return }
        cancelling = true
        defer { cancelling = false }
        session += 1; processingSegment = true
        task?.cancel(); await task?.value; task = nil
        await worker?.drain()
        active = false; finishing = false; processingSegment = false; scanningContainers = false; stopReason = nil; lastScrollPoint = nil; worker = nil; preview = ScrollPreview()
        containers = []; selectedContainerID = nil; manualScrollPoint = nil
        waitingForStableFrame = false; unstableRegions = []
        stabilityThumbnail = nil; targetActivationDeadline = nil
        targetThumbnail = nil
    }
}
