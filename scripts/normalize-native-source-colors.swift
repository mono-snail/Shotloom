import AppKit
// ColorSync normalization only. Pixel row composition is handled independently
// by Pillow; no seam positions, crops or resizes are used here.
let report = URL(fileURLWithPath: CommandLine.arguments[1])
let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: report.appendingPathComponent("deskcapture-quality-diagnostic.json"))) as! [String: Any]
let row = (metadata["cases"] as! [[String: Any]])[0]
let frames = row["frames"] as! Int
let folder = report.appendingPathComponent("normalized-sources", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for number in 1...frames {
    try autoreleasepool {
        let input = report.appendingPathComponent("artifacts/native-source-\(number).png")
        guard let decoder = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(decoder, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw NSError(domain: "NativeColorOracle", code: 1) }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage(), let encoder = CGImageDestinationCreateWithURL(folder.appendingPathComponent("native-source-\(number).png") as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "NativeColorOracle", code: 2) }
        CGImageDestinationAddImage(encoder, normalized, nil)
        guard CGImageDestinationFinalize(encoder) else { throw NSError(domain: "NativeColorOracle", code: 3) }
    }
}
print("Normalized \(frames) full source PNGs to sRGB; no geometry operations")
