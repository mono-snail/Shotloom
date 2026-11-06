import XCTest
import AppKit
@testable import DeskCapture

final class DesktopTopologyTests: XCTestCase {
    private func display(_ id: UInt32 = 1, identity: String = "display-a", frame: CGRect = CGRect(x: 0, y: 0, width: 1500, height: 1000), scale: CGFloat = 2, rotation: Double = 0, mirror: UInt32 = 0) -> CaptureDisplayGeometry {
        .init(id: id, identity: identity, frame: frame, quartzFrame: CGRect(x: frame.minX, y: 1000 - frame.maxY, width: frame.width, height: frame.height), scale: scale,
              pixelWidth: Int(frame.width * scale), pixelHeight: Int(frame.height * scale), rotation: rotation, mirrorOf: mirror)
    }
    func testNegativeOriginAndPortraitSourceRectUsesLocalHeight() throws {
        let portrait = display(2, identity: "portrait", frame: CGRect(x: -900, y: -300, width: 900, height: 1600), scale: 1, rotation: 90)
        let source = try portrait.sourceRect(CGRect(x: 10.5, y: 100.25, width: 300.5, height: 500.25))
        XCTAssertEqual(source, CGRect(x: 10.5, y: 999.5, width: 300.5, height: 500.25))
        XCTAssertThrowsError(try portrait.sourceRect(CGRect(x: -0.1, y: 0, width: 100, height: 100)))
        XCTAssertThrowsError(try portrait.sourceRect(CGRect(x: 800, y: 0, width: 101, height: 100)))
        XCTAssertThrowsError(try portrait.sourceRect(CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        XCTAssertThrowsError(try portrait.sourceRect(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
    }
    func testOrderChangeAloneIsCompatibleButIdentityReuseAndLayoutChangesAreNot() throws {
        let left = display(), right = display(2, identity: "display-b", frame: CGRect(x: 1500, y: 100, width: 1000, height: 1500), scale: 1, rotation: 90)
        let frozen = DesktopTopology(displays: [left, right])
        XCTAssertNoThrow(try frozen.requireUnchanged(.init(displays: [right, left])))
        XCTAssertThrowsError(try frozen.requireUnchanged(.init(displays: [left])))
        XCTAssertThrowsError(try frozen.requireUnchanged(.init(displays: [display(identity: "different-physical-display"), right])))
        XCTAssertThrowsError(try frozen.requireUnchanged(.init(displays: [display(scale: 1), right])))
        XCTAssertThrowsError(try frozen.requireUnchanged(.init(displays: [display(rotation: 180), right])))
        XCTAssertThrowsError(try frozen.requireUnchanged(.init(displays: [display(mirror: 2), right])))
        XCTAssertThrowsError(try frozen.requireUnchanged(.init(displays: [display(frame: CGRect(x: 0, y: 20, width: 1500, height: 1000)), right])))
    }
    @MainActor func testCombinedSnapshotUsesFrozenFramesAndImageScale() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        func image(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try XCTUnwrap(context.makeImage())
        }
        let left = ScreenSnapshot(screen: screen, image: try image(200, 200), capturedFrame: CGRect(x: -100, y: 0, width: 100, height: 100))
        let right = ScreenSnapshot(screen: screen, image: try image(100, 200), capturedFrame: CGRect(x: 0, y: 0, width: 100, height: 200))
        let combined = try XCTUnwrap(DesktopCapture.combine([left, right]))
        XCTAssertEqual(combined.frame, CGRect(x: -100, y: 0, width: 200, height: 200))
        XCTAssertEqual(combined.image.width, 400); XCTAssertEqual(combined.image.height, 400)
        XCTAssertEqual(combined.scale, 2)
    }
}
