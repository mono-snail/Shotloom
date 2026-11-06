import AppKit

// Independent files opened by real browsers; all content is generated test data.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func writeTexture(_ name: String, width: Int, height: Int, seed: UInt64) throws {
    try autoreleasepool {
        var state = seed, bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1
            let value = UInt8((state >> 32) & 255)
            bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
try writeTexture("vertical.png", width: 960, height: 9000, seed: 42)
try writeTexture("horizontal.png", width: 9000, height: 600, seed: 42)
try writeTexture("header.png", width: 960, height: 72, seed: 777)
try writeTexture("footer.png", width: 960, height: 56, seed: 778)
print(folder.path)
