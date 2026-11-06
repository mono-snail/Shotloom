import AppKit

@MainActor
final class OCRReferenceBenchmark {
    func run() async {
        defer { NSApp.terminate(nil) }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DESKCAPTURE_DIAGNOSTIC_DIR"] ?? NSTemporaryDirectory())
        var rows: [[String: Any]] = []
        func write(_ finished: Bool) {
            let report: [String: Any] = ["schema": 1, "finished": finished,
                "success": finished && rows.count == OCRReferenceCorpus.samples.count && rows.allSatisfy { $0["measured"] as? Bool == true },
                "scope": "Generated reference images; measured does not mean zero OCR error or competitor superiority",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cases": rows, "userContentUsed": false, "clipboardTouched": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("ocr-reference.json"), options: .atomic)
            }
        }
        write(false)
        for sample in OCRReferenceCorpus.samples {
            let began = ProcessInfo.processInfo.systemUptime
            do {
                let image = try await Task.detached {
                    let image = try OCRReferenceCorpus.render(sample)
                    try CaptureImageExport.png(image, to: root.appendingPathComponent(sample.id + ".png"))
                    return image
                }.value
                var row: [String: Any] = ["id": sample.id, "category": sample.category, "fontSizePixels": sample.fontSize,
                                         "expected": sample.expected, "image": sample.id + ".png", "measured": true]
                if sample.category == "qr" {
                    let actual = try await CaptureEngine.extract(image, destination: .qr)
                    row["actual"] = actual; row["payloadExact"] = actual == sample.expected
                } else {
                    let lines = try await CaptureEngine.recognizeLines(image)
                    let actual = lines.map(\.text).joined(separator: "\n")
                    let evidence = await Task.detached { () -> [String: Any] in
                        let expectedBounds = OCRReferenceCorpus.referenceBounds(sample)
                        var errors: [Double] = []
                        for (index, expected) in sample.lines.enumerated() where index < expectedBounds.count {
                            // Geometry is scored only for exact uniquely matched rows; report the denominator.
                            let matches = lines.filter { $0.text.trimmingCharacters(in: .whitespaces) == expected.trimmingCharacters(in: .whitespaces) }
                            if matches.count == 1 {
                                let a = matches[0].bounds.applying(CGAffineTransform(scaleX: CGFloat(image.width), y: CGFloat(image.height)))
                                let b = expectedBounds[index]
                                errors.append(Double(max(abs(a.minX-b.minX), abs(a.maxX-b.maxX), abs(a.minY-b.minY), abs(a.maxY-b.maxY))))
                            }
                        }
                        return ["strictCER": WorkflowMetrics.characterErrorRate(expected: sample.expected, actual: actual),
                                "nonWhitespaceCER": WorkflowMetrics.characterErrorRate(expected: sample.expected, actual: actual, ignoringWhitespace: true),
                                "locationScoredRows": errors.count, "locationReferenceRows": expectedBounds.count,
                                "locationMaximumEdgeErrorsPixels": errors]
                    }.value
                    row.merge(evidence) { _, new in new }; row["actual"] = actual
                    row["lowConfidenceRows"] = lines.filter(\.needsReview).count
                    row["recognizedRows"] = lines.map { ["text": $0.text, "confidence": $0.confidence, "alternatives": $0.alternatives,
                                                          "bounds": [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height]] as [String: Any] }
                    if let expected = sample.tableTSV {
                        row["expectedTSV"] = expected
                        do {
                            let actual = try await CaptureEngine.extract(image, destination: .table)
                            row["actualTSV"] = actual; row["tableStructureAndValuesExact"] = actual == expected
                        } catch { row["tableError"] = error.localizedDescription; row["tableStructureAndValuesExact"] = false }
                    }
                    if sample.category == "code" {
                        let code = try await CaptureEngine.extract(image, destination: .code)
                        row["actualCode"] = code
                        row["codeStrictCER"] = await Task.detached { WorkflowMetrics.characterErrorRate(expected: sample.expected, actual: code) }.value
                    }
                }
                row["seconds"] = ProcessInfo.processInfo.systemUptime - began; rows.append(row)
            } catch { rows.append(["id": sample.id, "measured": false, "error": error.localizedDescription]) }
            write(false)
        }
        write(true)
    }
}
