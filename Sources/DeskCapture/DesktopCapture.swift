import AppKit

@MainActor
enum DesktopCapture {
    static func combine(_ snapshots: [ScreenSnapshot]) -> ScreenSnapshot? {
        guard let first = snapshots.first else { return nil }
        let frame = snapshots.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let nativeScale = snapshots.map(\.scale).max() ?? 1
        let scale = min(nativeScale, sqrt(80_000_000 / max(1, frame.width * frame.height)), 60_000 / max(frame.width, frame.height))
        let width = max(1, Int(frame.width * scale)), height = max(1, Int(frame.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        for snapshot in snapshots {
            let rect = snapshot.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            context.draw(snapshot.image, in: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
        }
        guard let image = context.makeImage() else { return nil }
        return ScreenSnapshot(screen: first.screen, image: image, desktopFrame: frame, topology: first.topology)
    }
}

struct DesktopRegionMemory: Codable {
    struct Display: Codable, Equatable {
        var id: UInt32
        var frame: CGRect
        var scale: CGFloat
        var identity: String? = nil
    }
    var rect: CGRect
    var displays: [Display]
    @MainActor init(rect: CGRect, screens: [NSScreen]) {
        self.rect = rect; displays = screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32).map { Display(id: $0, frame: screen.frame, scale: screen.backingScaleFactor, identity: CaptureDisplayGeometry.identifier($0)) }
        }.sorted { $0.id < $1.id }
    }
    @MainActor func compatible(_ snapshots: [ScreenSnapshot]) -> Bool { displays == Self(rect: rect, screens: snapshots.map(\.screen)).displays }
}
