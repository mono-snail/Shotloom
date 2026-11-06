import AppKit

@MainActor
enum ScrollStreamDiagnostic {
    static func run(root: URL, inspect: Bool, present: (ScrollCapture) -> Void) async throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var uiEvents: [[String: Any]] = []
        if inspect {
            ScrollFileDialog.diagnosticTrace = { event in uiEvents.append(["event": event, "uptime": ProcessInfo.processInfo.systemUptime]) }
        }
        defer { if inspect { ScrollFileDialog.diagnosticTrace = nil } }
        let stitcher = try await Task.detached(priority: .userInitiated) {
            let value = try ScrollStitcher(detectsFixedEdges: false)
            for start in stride(from: 0, through: 21000, by: 500) {
                try autoreleasepool {
                    let frame = WorkflowCorpus.textureRows(width: 4000, start: start, height: 1000)
                    guard try value.append(frame) == (start == 0 ? 1000 : 500) else { throw CaptureError.message("Large capture seam failed") }
                }
            }
            return value
        }.value
        defer { withExtendedLifetime(stitcher) {} }
        let plan = try await Task.detached { try stitcher.exportPlan() }.value
        guard plan.width == 4000, plan.height == 22000, !plan.canRenderWhole else { throw CaptureError.message("Large capture did not exceed 80M pixels") }
        let model = ScrollCapture(stitcher: stitcher)
        var exported: URL?
        model.onStreamExport = { exported = $0 }
        let oldFolder = root.appendingPathComponent("cancel-preserved", isDirectory: true)
        try await Task.detached {
            try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: false)
            try Data("original-directory".utf8).write(to: oldFolder.appendingPathComponent("sentinel.txt"))
        }.value
        let cancelledExport = Task { await model.finish(output: .segments(oldFolder)) }
        var wroteFirstPart = false
        for _ in 0..<500 {
            wroteFirstPart = try await Task.detached {
                let stages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".DeskCapture-parts-") }
                return stages.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("part-00001.png").path) }
            }.value
            if wroteFirstPart || !model.active || exported != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.cancel(); await cancelledExport.value
        guard wroteFirstPart, exported == nil, model.active, model.paused, !model.finishing,
              model.frames == 43, model.preview.width == 4000, model.preview.height == 22000 else {
            throw CaptureError.message("Partial export cancellation did not preserve the capture session")
        }
        try await Task.detached {
            guard try Data(contentsOf: oldFolder.appendingPathComponent("sentinel.txt")) == Data("original-directory".utf8),
                  !FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent("manifest.json").path),
                  !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".DeskCapture-parts-") }) else {
                throw CaptureError.message("Partial cancellation changed the existing destination or left staging artifacts")
            }
        }.value
        let destination = root.appendingPathComponent("large-parts", isDirectory: true)
        if inspect {
            present(model)
            let ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "target": destination.path,
                                        "width": plan.width, "height": plan.height]
            let directory = ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] ?? root.path
            try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: directory).appendingPathComponent("stream-ui-ready.json"), options: .atomic)
            for _ in 0..<1200 where exported == nil { try await Task.sleep(for: .milliseconds(100)) }
            guard exported != nil else { await model.cancel(); throw CaptureError.message("Stream UI export was not completed") }
        } else { await model.finish(output: .segments(destination)) }
        guard let exported, !model.active else { throw CaptureError.message(model.warning ?? "Large model export failed") }
        let verification = try await Task.detached(priority: .userInitiated) { () throws -> [String: Any] in
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: exported.appendingPathComponent("manifest.json"))) as? [String: Any]
            guard data?["width"] as? Int == 4000, data?["height"] as? Int == 22000,
                  let parts = data?["parts"] as? [[String: Any]], parts.count == 6 else { throw CaptureError.message("Large bundle manifest incomplete") }
            var pixelCount = 0
            for part in parts {
                guard let name = part["file"] as? String, let x = part["x"] as? Int, let y = part["y"] as? Int,
                      let width = part["width"] as? Int, let height = part["height"] as? Int else { throw CaptureError.message("Large manifest coordinates missing") }
                try autoreleasepool {
                    let image = try CaptureImageRead.load(exported.appendingPathComponent(name))
                    guard image.width == width, image.height == height else { throw CaptureError.message("Large part unreadable") }
                    // Independent input rows at both ends of every fully written
                    // block prove continuity without allocating the whole oracle.
                    for localY in [0, max(0, height - 2)] {
                        guard let sample = image.cropping(to: CGRect(x: 0, y: localY, width: width, height: 2)) else { throw CaptureError.message("Cannot sample part") }
                        let expected = WorkflowCorpus.textureRows(width: 4000, start: y + localY, height: 2)
                        let oracle = expected.cropping(to: CGRect(x: x, y: 0, width: width, height: 2))!
                        guard rgba(sample) == rgba(oracle) else { throw CaptureError.message("Large part coordinate mismatch") }
                    }
                }
                pixelCount += width * height
            }
            guard pixelCount == 88_000_000 else { throw CaptureError.message("Large parts lost pixels") }
            let pdf = root.appendingPathComponent("large-pages.pdf")
            try plan.exportPDF(to: pdf)
            guard let document = CGPDFDocument(pdf as CFURL), document.numberOfPages == 4 else { throw CaptureError.message("Large PDF not readable or wrong page count") }
            return ["pixels": "4000x22000", "totalPixels": pixelCount, "parts": parts.count, "pdfPages": document.numberOfPages,
                    "boundedPNGReadback": true, "wholeBitmapRequested": false]
        }.value
        var result = verification
        result["secondsIncludingCapture"] = ProcessInfo.processInfo.systemUptime - started
        result["uiExportVerified"] = inspect; result["clipboardTouched"] = false; result["userContentUsed"] = false
        result["uiEvents"] = uiEvents
        result["cancelledAfterFirstPNG"] = wroteFirstPart
        result["cancelPreservedDirectoryAndSession"] = true
        return result
    }
    private nonisolated static func rgba(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
}
