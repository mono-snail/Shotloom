import XCTest
import AppKit
@testable import DeskCapture

@MainActor
final class ScrollVisibilityTests: XCTestCase {
    func testFractionalRetinaSelectionCapturesWholePointsThenCropsExactPixels() {
        let raster = ScrollFrameRaster(source: CGRect(x: 116, y: 167.5, width: 593, height: 384.5), scale: 2)
        XCTAssertEqual(raster.source, CGRect(x: 116, y: 167, width: 593, height: 385))
        XCTAssertEqual(raster.width, 1186)
        XCTAssertEqual(raster.height, 770)
        XCTAssertEqual(raster.crop, CGRect(x: 0, y: 1, width: 1186, height: 769))
        for scale: CGFloat in [1, 2] {
            let whole = CGRect(x: 10, y: 20, width: 400, height: 300)
            let raster = ScrollFrameRaster(source: whole, scale: scale)
            XCTAssertEqual(raster.source, whole)
            XCTAssertEqual(raster.crop, CGRect(x: 0, y: 0, width: 400 * scale, height: 300 * scale))
        }
        let both = ScrollFrameRaster(source: CGRect(x: 10.5, y: 20.5, width: 400.5, height: 300.5), scale: 2)
        XCTAssertEqual(both.crop, CGRect(x: 1, y: 1, width: 801, height: 601))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: both.width, height: both.height).contains(both.crop))
    }

    func testWindowCoverageRejectsAnyForeignOverlapAndOutsideSelection() {
        let display = CGRect(x: -1000, y: -400, width: 1000, height: 800)
        let selection = CGRect(x: -900, y: -300, width: 500, height: 400)
        func item(_ id: UInt32, _ pid: Int32, _ rect: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowBounds as String: rect.dictionaryRepresentation, kCGWindowLayer as String: layer]
        }
        let target = item(1, 10, display)
        func clear(_ windows: [[String: Any]]) -> Bool {
            ScrollWindowVisibility.clear(region: selection, target: 1, ownPID: 20, display: display,
                windows: windows, bundlePath: { $0 == 30 ? "/System/Library/CoreServices/Dock.app" : nil })
        }
        var cursor = item(2, 415, selection, layer: Int(CGWindowLevelForKey(.cursorWindow)))
        cursor[kCGWindowOwnerName as String] = "Window Server"
        cursor[kCGWindowName as String] = "Cursor"
        XCTAssertTrue(clear([cursor, target]))
        cursor.removeValue(forKey: kCGWindowName as String)
        XCTAssertTrue(clear([cursor, target]), "Untitled WindowServer cursor surfaces must not block capture")
        cursor[kCGWindowName as String] = ""
        XCTAssertTrue(clear([cursor, target]))
        cursor[kCGWindowName as String] = "StatusIndicator"
        XCTAssertFalse(clear([cursor, target]))
        cursor[kCGWindowName as String] = "Cursor"
        cursor[kCGWindowOwnerName as String] = "Other App"
        XCTAssertFalse(clear([cursor, target]))
        XCTAssertTrue(clear([target]))
        XCTAssertTrue(clear([item(2, 20, selection), target]), "Our excluded controls do not cover target pixels")
        XCTAssertFalse(clear([item(2, 11, CGRect(x: -901, y: -301, width: 2, height: 2)), target]))
        XCTAssertFalse(clear([item(2, 10, selection), target]), "Another window in the target app still covers the selection")
        var namedCover = item(2, 11, selection)
        namedCover[kCGWindowOwnerName as String] = "截屏"
        let reason = ScrollWindowVisibility.failure(region: selection, target: 1, ownPID: 20,
            display: display, windows: [namedCover, target], bundlePath: { _ in nil })
        XCTAssertEqual(reason, .coveredBy("截屏"))
        XCTAssertTrue(reason?.message.contains("截屏") == true)
        XCTAssertFalse(clear([item(1, 10, selection.insetBy(dx: 1, dy: 1))]))
        XCTAssertFalse(clear([]))
        XCTAssertTrue(clear([item(2, 30, display, layer: 20), target]))
        XCTAssertFalse(clear([item(2, 31, display, layer: 20), target]))
        XCTAssertFalse(clear([item(2, 30, selection, layer: 20), target]))
    }

    func testGeometricOcclusionRetriesWithoutDeliveringPixels() async throws {
        let target = image()
        var calls = 0
        let result = try await ScrollVisibleFrame.acquire(interval: .zero) {
            calls += 1
            if calls == 1 { throw ScrollVisibleFrame.Occluded() }
            return (target, target)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(result === target)
    }

    private func image(width: Int = 17, height: Int = 260, changed: Int? = nil, alpha: UInt8 = 255,
                       transparentPixel: Int? = nil) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = 40; bytes[i+1] = 70; bytes[i+2] = 90; bytes[i+3] = alpha
        }
        if let changed { bytes[changed * 4] = 220 }
        if let transparentPixel { bytes[transparentPixel * 4 + 3] = 0 }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testEveryPixelIncludingStripBoundariesAndCornersIsChecked() throws {
        let original = image()
        XCTAssertTrue(try ScrollFrameVisibility.matches(display: original, target: image()))
        for pixel in [0, 16, 127 * 17 + 8, 128 * 17 + 8, 259 * 17 + 16] {
            XCTAssertFalse(try ScrollFrameVisibility.matches(display: original, target: image(changed: pixel)))
        }
    }

    func testTransparencyAndInvalidGeometryCannotVerifyAFrame() throws {
        let transparent = image(alpha: 200)
        XCTAssertFalse(try ScrollFrameVisibility.matches(display: transparent, target: transparent))
        XCTAssertThrowsError(try ScrollFrameVisibility.matches(display: image(), target: image(width: 18)))
        XCTAssertThrowsError(try ScrollFrameVisibility.matches(display: image(), target: image(), tolerance: 5))
    }

    func testTargetOnlyTransparentEdgesArePreservedButBodyStillMustBeOpaque() async throws {
        let corner = image(transparentPixel: 0)
        XCTAssertTrue(try ScrollFrameVisibility.matches(display: corner, target: corner, transparentBorder: 8))
        let result = try await ScrollVisibleFrame.acquire(interval: .zero, transparentBorder: 8) { (corner, corner) }
        XCTAssertTrue(result === corner, "Keep original alpha; never import desktop pixels or fill the edge")
        let rendered = try await Task.detached {
            let stitcher = try ScrollStitcher()
            _ = try stitcher.append(corner)
            return try stitcher.render()
        }.value
        XCTAssertTrue(try ScrollFrameVisibility.matches(display: rendered, target: corner, transparentBorder: 8),
                      "Disk tiles and export must preserve transparent edges")
        let interior = image(transparentPixel: 130 * 17 + 8)
        XCTAssertFalse(try ScrollFrameVisibility.matches(display: interior, target: interior, transparentBorder: 8))
        let transparent = image(alpha: 200)
        XCTAssertFalse(try ScrollFrameVisibility.matches(display: transparent, target: transparent, transparentBorder: 64))
        let differentCorner = image(changed: 1, transparentPixel: 0)
        XCTAssertFalse(try ScrollFrameVisibility.matches(display: corner, target: differentCorner, transparentBorder: 8))
        var calls = 0
        do {
            _ = try await ScrollVisibleFrame.acquire(maxPairs: 1, transparentBorder: 8) {
                calls += 1; return (corner, self.image(transparentPixel: 0))
            }
            XCTFail("Separate display/reference images must retain opaque proof")
        } catch { XCTAssertEqual(calls, 1) }
    }

    func testGeometryFailureReportsOutsideSelectionInsteadOfGenericOcclusion() async throws {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 600)
        let target: [String: Any] = [kCGWindowNumber as String: UInt32(1),
            kCGWindowBounds as String: rect.dictionaryRepresentation]
        XCTAssertEqual(ScrollWindowVisibility.failure(region: rect.offsetBy(dx: 1, dy: 0), target: 1,
            ownPID: 20, display: rect, windows: [target], bundlePath: { _ in nil }), .outsideTarget)
        XCTAssertEqual(ScrollWindowVisibility.failure(region: rect, target: 1,
            ownPID: 20, display: rect, windows: [], bundlePath: { _ in nil }), .targetUnavailable)
        do {
            _ = try await ScrollVisibleFrame.acquire(maxPairs: 1) { throw ScrollVisibleFrame.Occluded(reason: .outsideTarget) }
            XCTFail("Outside selection accepted")
        } catch { XCTAssertEqual(error.localizedDescription, L10n.text("选区超出了目标窗口边界。请把整个长图选区放在同一个窗口内；已有片段会保留。")) }
    }

    func testRetryOnlyDeliversTheVerifiedDisplayFrame() async throws {
        let target = image(), blocked = image(changed: 16)
        var calls = 0
        let result = try await ScrollVisibleFrame.acquire(interval: .zero) {
            calls += 1
            return (calls == 1 ? blocked : target, target)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(result === target)
    }

    func testExhaustionAndInvalidBudgetNeverDeliver() async throws {
        let target = image(), blocked = image(changed: 16)
        var calls = 0
        do {
            _ = try await ScrollVisibleFrame.acquire(maxPairs: 2, interval: .zero) { calls += 1; return (blocked, target) }
            XCTFail("Occluded image delivered")
        } catch { XCTAssertEqual(calls, 2) }
        do {
            _ = try await ScrollVisibleFrame.acquire(maxPairs: 0) { calls += 1; return (target, target) }
            XCTFail("Invalid budget accepted")
        } catch { XCTAssertEqual(calls, 2) }
    }

    func testCancellationDuringRetryDoesNotCaptureAgain() async throws {
        let target = image(), blocked = image(changed: 16)
        var calls = 0
        let task = Task {
            try await ScrollVisibleFrame.acquire(interval: .seconds(10)) { calls += 1; return (blocked, target) }
        }
        while calls == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled image delivered") }
        catch is CancellationError { XCTAssertEqual(calls, 1) }
    }

    func testObsoleteSessionPropagatesWithoutRetry() async throws {
        var calls = 0
        do {
            _ = try await ScrollVisibleFrame.acquire(interval: .zero) { calls += 1; throw ScrollVisibleFrame.Obsolete() }
            XCTFail("Obsolete image delivered")
        } catch is ScrollVisibleFrame.Obsolete { XCTAssertEqual(calls, 1) }
    }

    func testRecordingDiagnosticRejectsForeignOrMissingSources() throws {
        let fixture = URL(fileURLWithPath: "/owned/ScrollFixtureTarget.app")
        XCTAssertTrue(DiagnosticRecordingSource.permits(windowID: 1, processID: 2, bundle: fixture, fixture: fixture))
        XCTAssertFalse(DiagnosticRecordingSource.permits(windowID: 0, processID: 2, bundle: fixture, fixture: fixture))
        XCTAssertFalse(DiagnosticRecordingSource.permits(windowID: 1, processID: 0, bundle: fixture, fixture: fixture))
        XCTAssertFalse(DiagnosticRecordingSource.permits(windowID: 1, processID: 2, bundle: nil, fixture: fixture))
        XCTAssertFalse(DiagnosticRecordingSource.permits(windowID: 1, processID: 2, bundle: URL(fileURLWithPath: "/foreign/App.app"), fixture: fixture))
        XCTAssertThrowsError(try DiagnosticRecordingSource.require(nil))
    }
}
