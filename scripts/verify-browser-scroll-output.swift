import AppKit

// Full-resolution RGBA readback, independent of the production seam matcher.
// Only generated fixture inputs and the explicit diagnostic output are read.
let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fixture = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let resultURL = reportURL.deletingLastPathComponent().appendingPathComponent("verified-pixels.json")
enum VerificationError: Error { case invalid(String) }
func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let value = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw VerificationError.invalid("Unreadable PNG") }
    return value
}
func context(_ width: Int, _ height: Int) throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw VerificationError.invalid("RGBA allocation failed") }
    return result
}
func verify() throws -> [String: Any] {
    let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as! [String: Any]
    guard report["scope"] as? String == "browser-debug-only", let row = (report["cases"] as? [[String: Any]])?.first,
          row["success"] as? Bool == true, let id = row["fixtureCase"] as? String,
          let output = row["output"] as? String, let initial = row["initialState"] as? [String: Any],
          let final = row["finalState"] as? [String: Any], let frames = row["frames"] as? Int, frames >= 2,
          let scale = initial["scale"] as? Double, let rect = initial["rect"] as? [Double], rect.count == 4,
          let axis = initial["axis"] as? String, let fixed = initial["fixed"] as? Bool,
          let events = final["wheelEvents"] as? [[String: Any]], events.count >= frames - 1,
          let start = initial[axis == "vertical" ? "scrollY" : "scrollX"] as? Double,
          let end = events[frames - 2]["position"] as? Double else { throw VerificationError.invalid("Independent applied-position transcript missing") }
    let outputURL = URL(fileURLWithPath: output)
    guard frames >= 2, outputURL.lastPathComponent == "browser-\(id).png",
          outputURL.deletingLastPathComponent().lastPathComponent.hasPrefix("DeskCapture-quality-") else { throw VerificationError.invalid("Unexpected output path") }
    let vertical = axis == "vertical", displacement = Int((abs(end - start) * scale).rounded())
    let width = Int((rect[2] * scale).rounded()) + (vertical ? 0 : displacement)
    let height = Int((rect[3] * scale).rounded()) + (vertical ? displacement : 0)
    let captured = try image(outputURL)
    guard captured.width == width, captured.height == height else { throw VerificationError.invalid("Output dimensions disagree with browser-applied positions") }
    let leading = fixed ? Int(36 * scale) : 0, trailing = fixed ? Int(28 * scale) : 0
    let bodyLength = (vertical ? height : width) - leading - trailing
    let low = Int((min(start, end) * scale).rounded())
    let original = try image(fixture.appendingPathComponent(vertical ? "vertical.png" : "horizontal.png"))
    guard let body = original.cropping(to: vertical ? CGRect(x: 0, y: low, width: width, height: bodyLength) : CGRect(x: low, y: 0, width: bodyLength, height: height)) else { throw VerificationError.invalid("Original-page crop outside input") }
    let expected = try context(width, height), actual = try context(width, height)
    expected.draw(body, in: vertical ? CGRect(x: 0, y: trailing, width: width, height: bodyLength) : CGRect(x: leading, y: 0, width: bodyLength, height: height))
    if fixed {
        guard vertical else { throw VerificationError.invalid("Horizontal fixed bars are not part of this corpus") }
        expected.draw(try image(fixture.appendingPathComponent("header.png")), in: CGRect(x: 0, y: height - leading, width: width, height: leading))
        expected.draw(try image(fixture.appendingPathComponent("footer.png")), in: CGRect(x: 0, y: 0, width: width, height: trailing))
    }
    actual.draw(captured, in: CGRect(x: 0, y: 0, width: width, height: height))
    let count = width * height * 4
    let a = actual.data!.assumingMemoryBound(to: UInt8.self), b = expected.data!.assumingMemoryBound(to: UInt8.self)
    var differingPixels = 0, maximumError = 0, totalError: UInt64 = 0
    for pixel in stride(from: 0, to: count, by: 4) {
        var different = false
        for channel in 0..<4 {
            let error = abs(Int(a[pixel + channel]) - Int(b[pixel + channel]))
            totalError += UInt64(error); maximumError = max(maximumError, error); different = different || error > 0
        }
        if different { differingPixels += 1 }
    }
    return ["fixtureCase": id, "success": differingPixels == 0, "fullResolutionRGBA": true,
            "width": width, "height": height, "pixelsCompared": width * height,
            "differingPixels": differingPixels, "maximumChannelError": maximumError,
            "meanChannelError": Double(totalError) / Double(count), "output": output]
}
do {
    let result = try autoreleasepool { try verify() }
    let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
    try bytes.write(to: resultURL, options: .atomic)
    print(String(data: bytes, encoding: .utf8)!)
    exit(result["success"] as? Bool == true ? 0 : 1)
} catch {
    let result: [String: Any] = ["success": false, "error": String(describing: error), "fullResolutionRGBA": false]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: resultURL, options: .atomic)
    print(error); exit(1)
}
