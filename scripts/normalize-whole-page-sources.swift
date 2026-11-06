import AppKit
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("deskcapture-quality-diagnostic.json"))) as! [String: Any]
let output = folder.appendingPathComponent("normalized-sources")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for row in data["cases"] as! [[String: Any]] {
    guard row["success"] as? Bool == true else { continue }
    let name = row["direction"] as! String, count = row["frames"] as! Int
    for number in 1...count {
        try autoreleasepool {
            let file = "whole-page-\(name)-source-\(number).png"
            let url = folder.appendingPathComponent("artifacts").appendingPathComponent(file)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw NSError(domain: "WholePageNormalization", code: 1) }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let normalized = context.makeImage(), let encoder = CGImageDestinationCreateWithURL(output.appendingPathComponent(file) as CFURL, "public.png" as CFString, 1, nil) else { throw NSError(domain: "WholePageNormalization", code: 2) }
            CGImageDestinationAddImage(encoder, normalized, nil)
            guard CGImageDestinationFinalize(encoder) else { throw NSError(domain: "WholePageNormalization", code: 3) }
        }
    }
}
