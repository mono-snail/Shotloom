import AppKit
import CoreText
import ScreenCaptureKit

/// Developer-only corpus: synthetic text and deterministic pixel textures.
/// Never uses user captures, clipboard, history, preferences or network access.
enum WorkflowCorpus {
    static let schema = 1
    static let trainingSeed: UInt64 = 42
    static let holdoutSeed: UInt64 = 0xD35C_A971
    static let ocrCases: [(id: String, text: String, font: String)] = [
        ("english", "DeskCapture baseline\nCapture, edit, deliver.\n0123456789", "Menlo"),
        ("mixed", "截图与文字识别 DeskCapture\n价格 Price: 128.50\n本地处理 Local processing", "PingFangSC-Regular"),
        ("code", "func add(a: Int, b: Int) -> Int {\n    return a + b\n}", "Menlo")
    ]
    static func texture(width: Int, height: Int, seed: UInt64) -> CGImage {
        var state = seed, pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1
            let value = UInt8((state >> 32) & 255)
            pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func textureRows(width: Int, start: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        var count = UInt64(start) * UInt64(width)
        var multiplier: UInt64 = 6364136223846793005, addend: UInt64 = 1
        var accumulatedMultiplier: UInt64 = 1, accumulatedAddend: UInt64 = 0
        while count > 0 {
            if count & 1 != 0 {
                accumulatedMultiplier = accumulatedMultiplier &* multiplier
                accumulatedAddend = accumulatedAddend &* multiplier &+ addend
            }
            addend = (multiplier &+ 1) &* addend; multiplier = multiplier &* multiplier
            count >>= 1
        }
        return texture(width: width, height: height, seed: accumulatedMultiplier &* seed &+ accumulatedAddend)
    }
    static func text(_ value: String, font: String, width: Int = 1600, height: Int = 600) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, line) in value.components(separatedBy: "\n").enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, 32, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 48, y: height - 72 - index * 64)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return context.makeImage()!
    }
}

enum WorkflowMetrics {
    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }), fraction.isFinite, (0...1).contains(fraction) else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    /// Unicode-character edit distance; capped corpus inputs avoid large allocations.
    static func characterErrorRate(expected: String, actual: String, ignoringWhitespace: Bool = false) -> Double {
        let a = Array(ignoringWhitespace ? expected.filter { !$0.isWhitespace } : expected)
        let b = Array(ignoringWhitespace ? actual.filter { !$0.isWhitespace } : actual)
        var previous = Array(0...b.count)
        for (i, reference) in a.enumerated() {
            var current = [Int](repeating: 0, count: b.count + 1); current[0] = i + 1
            for (j, observed) in b.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (reference == observed ? 0 : 1))
            }
            previous = current
        }
        return Double(previous.last ?? 0) / Double(max(1, a.count))
    }
}

@MainActor
final class WorkflowBenchmarks {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-baseline-\(UUID())")
    private var cases: [[String: Any]] = []
    private var mode = "api-stages"
    private var report: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] ?? "/tmp")
            .appendingPathComponent("deskcapture-workflow-baseline.json")
    }
    private func write(finished: Bool) {
        let values: [String: Any] = [
            "schema": WorkflowCorpus.schema, "measurementMode": mode, "finished": finished,
            "success": finished && cases.allSatisfy { $0["success"] as? Bool == true },
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "corpus": "synthetic-v1", "trainingSeed": WorkflowCorpus.trainingSeed,
            "holdoutSeed": WorkflowCorpus.holdoutSeed, "artifacts": root.path,
            "cases": cases, "competitorMeasurements": [],
            "coverageLimits": ["No competitor binaries/authorization measured", "API-stage latency is not hotkey-to-UI or copy latency", "Synthetic OCR/scroll corpus is not real-app compatibility", "Holdout seed reserved; not benchmarked here", "Recording measurements are in the companion current signed quality report"]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
    }
    private func measure(_ name: String, count: Int, body: () async throws -> [String: Any]) async {
        var durations: [Double] = [], evidence: [String: Any] = [:]
        do {
            for _ in 0..<count {
                let start = ProcessInfo.processInfo.systemUptime
                evidence = try await body()
                durations.append(ProcessInfo.processInfo.systemUptime - start)
            }
            cases.append(["case": name, "success": true, "samplesSeconds": durations,
                          "medianSeconds": WorkflowMetrics.percentile(durations, fraction: 0.5)!,
                          "p95Seconds": WorkflowMetrics.percentile(durations, fraction: 0.95)!, "evidence": evidence])
        } catch { cases.append(["case": name, "success": false, "error": String(describing: error), "samplesSeconds": durations]) }
        write(finished: false)
    }
    func runCaptureUI() async {
        mode = "coordinator-ui-with-named-pasteboard"
        defer { NSApp.terminate(nil) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { cases.append(["case": "setup", "success": false, "error": String(describing: error)]); write(finished: true); return }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DeskCapture-UI-benchmark-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let app = AppCoordinator(store: CaptureStore(directory: root.appendingPathComponent("history")),
                                 imagePasteboard: pasteboard, registerHotKeys: false)
        func captureSample() async throws -> [String: Any] {
            var presented = false
            app.onSelectionPresented = { presented = true }
            defer { app.onSelectionPresented = nil; app.cancelCapture() }
            app.start(.region)
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !presented && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard presented else { throw CaptureError.message(app.notice ?? "Selection presentation exceeded 10 seconds") }
            return ["boundary": "Coordinator.start through native selection display pass and first responder", "includesPhysicalHotkeyDispatch": false]
        }
        await measure("selection-ui-first", count: 1) { try await captureSample() }
        await measure("selection-ui-repeated", count: 5) { try await captureSample() }
        let source = await Task.detached { WorkflowCorpus.texture(width: 1600, height: 900, seed: WorkflowCorpus.trainingSeed) }.value
        await measure("synthetic-image-to-named-pasteboard", count: 5) {
            var copied = false
            app.onImageCopyCompleted = { copied = true }
            defer { app.onImageCopyCompleted = nil }
            app.copy(source)
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !copied && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard copied, let data = pasteboard.data(forType: .png),
                  let decoded = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil), image.width == 1600, image.height == 900 else {
                throw CaptureError.message("Named-pasteboard copy failed")
            }
            return ["pixels": "1600x900", "boundary": "Coordinator.copy through PNG/TIFF pasteboard write and PNG readback", "systemPasteboardTouched": false]
        }
        write(finished: true)
    }

    func run() async {
        defer { NSApp.terminate(nil) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { cases.append(["case": "setup", "success": false, "error": String(describing: error)]); write(finished: true); return }
        write(finished: false)
        let engine = CaptureEngine()
        await measure("native-region-api", count: 10) {
            let content = try await engine.content()
            guard let screen = NSScreen.screens.first(where: { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
                return content.displays.contains { $0.displayID == id }
            }) else { throw CaptureError.message("No matching screen") }
            let image = try await engine.region(CGRect(x: 20, y: 100, width: 600, height: 340), screen: screen, content: content)
            return ["pixels": "\(image.width)x\(image.height)", "includesContentQuery": true, "clipboardTouched": false]
        }
        for item in WorkflowCorpus.ocrCases {
            let image = await Task.detached { WorkflowCorpus.text(item.text, font: item.font) }.value
            try? await Task.detached { try CaptureImageExport.png(image, to: self.root.appendingPathComponent("\(item.id).png")) }.value
            await measure("ocr-\(item.id)", count: 3) {
                let actual = try await CaptureEngine.recognize(image)
                return ["expected": item.text, "actual": actual,
                        "strictCER": WorkflowMetrics.characterErrorRate(expected: item.text, actual: actual),
                        "nonWhitespaceCER": WorkflowMetrics.characterErrorRate(expected: item.text, actual: actual, ignoringWhitespace: true),
                        "font": item.font, "pixels": "1600x600"]
            }
        }
        for axis in [ScrollAxis.vertical, .horizontal] {
            let pair = await Task.detached { () -> (CGImage, CGImage) in
                let vertical = axis == .vertical
                let page = WorkflowCorpus.texture(width: vertical ? 1200 : 5200, height: vertical ? 5200 : 1200, seed: WorkflowCorpus.trainingSeed)
                let width = vertical ? 1200 : 3200, height = vertical ? 3200 : 1200
                return (page.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))!,
                        page.cropping(to: CGRect(x: vertical ? 0 : 1137, y: vertical ? 1137 : 0, width: width, height: height))!)
            }.value
            await measure("scroll-\(axis)-exact", count: 10) {
                let offset = await Task.detached { ScrollMatcher.match(previous: pair.0, next: pair.1, axis: axis)?.offset }.value
                guard offset == 1137 else { throw CaptureError.message("Incorrect seam: \(String(describing: offset))") }
                return ["expectedOffset": 1137, "actualOffset": offset!, "seed": WorkflowCorpus.trainingSeed]
            }
        }
        let image = await Task.detached { WorkflowCorpus.text("DeskCapture image export fixture", font: "Menlo", width: 3840, height: 2160) }.value
        await measure("png-export-4k", count: 5) {
            let destination = self.root.appendingPathComponent("export.png")
            try await Task.detached { try CaptureImageExport.png(image, to: destination) }.value
            let valid = await Task.detached { () -> Bool in
                guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
                return decoded.width == 3840 && decoded.height == 2160
            }.value
            guard valid else { throw CaptureError.message("PNG readback failed") }
            return ["pixels": "3840x2160", "includesReadback": true]
        }
        write(finished: true)
    }
}
