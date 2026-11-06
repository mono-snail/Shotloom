import AppKit

struct CaptureDisplayGeometry: Equatable, Sendable {
    let id: UInt32
    let identity: String
    let frame: CGRect
    let quartzFrame: CGRect
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let rotation: Double
    let mirrorOf: UInt32
    static func identifier(_ id: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    func sourceRect(_ rect: CGRect) throws -> CGRect {
        let values = [rect.minX, rect.minY, rect.width, rect.height, frame.width, frame.height, scale]
        guard values.allSatisfy(\.isFinite), scale > 0, rect.width > 0, rect.height > 0,
              CGRect(origin: .zero, size: frame.size).contains(rect), rect.width * scale >= 1, rect.height * scale >= 1 else {
            throw CaptureError.message(L10n.text("选区已超出原显示器或尺寸无效，请重新选择。"))
        }
        return CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
struct DesktopTopology: Equatable, Sendable {
    let displays: [CaptureDisplayGeometry]
    init(displays: [CaptureDisplayGeometry]) { self.displays = displays.sorted { $0.id < $1.id } }
    @MainActor static func current() -> Self {
        Self(displays: NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  CGDisplayIsActive(id) != 0, let identity = CaptureDisplayGeometry.identifier(id) else { return nil }
            return CaptureDisplayGeometry(id: id, identity: identity, frame: screen.frame,
                quartzFrame: CGDisplayBounds(id), scale: screen.backingScaleFactor,
                pixelWidth: CGDisplayPixelsWide(id), pixelHeight: CGDisplayPixelsHigh(id), rotation: CGDisplayRotation(id), mirrorOf: CGDisplayMirrorsDisplay(id))
        })
    }
    func requireUnchanged(_ current: Self) throws {
        guard self == current else { throw CaptureError.message(L10n.text("显示器连接、排列、缩放或旋转已改变，已保留捕获内容。请重新选择目标后开始新的捕获。")) }
    }
    @MainActor func requireUnchanged() throws { try requireUnchanged(Self.current()) }
    @MainActor func display(for screen: NSScreen) throws -> CaptureDisplayGeometry {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let display = displays.first(where: { $0.id == id }), display.frame == screen.frame, display.scale == screen.backingScaleFactor else { throw CaptureError.message(L10n.text("原显示器已断开或参数改变，请重新选择。")) }
        return display
    }
}
