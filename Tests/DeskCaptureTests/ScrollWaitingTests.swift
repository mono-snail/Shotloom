import XCTest
import AppKit
@testable import DeskCapture

final class ScrollWaitingTests: XCTestCase {
    func testManualMotionAcceptsTranslatedContentButRejectsUnrelatedAnimation() throws {
        let page = WorkflowCorpus.texture(width: 400, height: 1600, seed: 42)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 600)))
        let next = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 400, height: 600)))
        XCTAssertFalse(ScrollFrameStability.compare(first, next).stable)
        XCTAssertTrue(ScrollFrameStability.compareManual(first, next, axis: .vertical, direction: .forward).stable)
        XCTAssertTrue(ScrollFrameStability.compareManual(next, first, axis: .vertical, direction: .reverse).stable)
        let unrelated = WorkflowCorpus.texture(width: 400, height: 600, seed: 987)
        XCTAssertFalse(ScrollFrameStability.compareManual(first, unrelated, axis: .vertical, direction: .forward).stable)
        let stitcher = try ScrollStitcher()
        XCTAssertNotNil(try stitcher.append(first))
        for y in stride(from: 113, through: 904, by: 113) {
            let frame = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: y, width: 400, height: 600)))
            XCTAssertEqual(try stitcher.append(frame), 113)
        }
        XCTAssertEqual(stitcher.totalHeight, 1504)
    }
    func testExplicitResumeReleasesOldResponseButPreservesMissingSeam() {
        var progress = ScrollCaptureProgress()
        progress.didScroll(); progress.observe(0)
        XCTAssertFalse(progress.shouldScroll)
        progress.resumeAtCurrentPosition()
        XCTAssertTrue(progress.shouldScroll)
        progress.didScroll(); progress.observe(nil)
        progress.resumeAtCurrentPosition()
        XCTAssertFalse(progress.shouldScroll)
    }

    func testContinuousMotionPausesWithoutAcceptingAndStableFrameResetsBudget() {
        var gate = ScrollStabilityGate()
        XCTAssertEqual(gate.evaluate(stable: false, now: 100), .wait)
        XCTAssertEqual(gate.evaluate(stable: false, now: 107.99), .wait)
        XCTAssertEqual(gate.evaluate(stable: false, now: 108), .pause)
        XCTAssertEqual(gate.evaluate(stable: false, now: 109), .pause)
        XCTAssertEqual(gate.evaluate(stable: true, now: 110), .accept)
        XCTAssertEqual(gate.evaluate(stable: false, now: 120), .wait)
        XCTAssertEqual(gate.evaluate(stable: false, now: 128), .pause)
        // Resume/mode changes start a new budget; they never force acceptance.
        gate = ScrollStabilityGate()
        XCTAssertEqual(gate.evaluate(stable: false, now: 150), .wait)
    }
    func testUnchangedFrameDoesNotAllocateDynamicPreview() throws {
        let image = WorkflowCorpus.texture(width: 400, height: 600, seed: 42)
        let result = ScrollFrameStability.compare(image, image)
        XCTAssertTrue(result.stable)
        XCTAssertTrue(result.regions.isEmpty)
        XCTAssertNil(result.thumbnail)
    }

    func testEqualGrayscaleColorsStillCountAsBroadChange() throws {
        func solid(_ red: CGFloat, _ green: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, 0, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 50)); return try XCTUnwrap(context.makeImage())
        }
        let red = try solid(1, 0), target = ScrollMatcher.grayscale(red)[0]
        var lower: CGFloat = 0, upper: CGFloat = 1, green = try solid(0, 0)
        for _ in 0..<14 {
            let mid = (lower + upper) / 2
            green = try solid(0, mid)
            let level = ScrollMatcher.grayscale(green)[0]
            if level == target { break }
            if level < target { lower = mid } else { upper = mid }
        }
        XCTAssertEqual(ScrollMatcher.grayscale(green)[0], target)
        XCTAssertFalse(ScrollFrameStability.compare(red, green).stable)
    }
    func testPartialTransitionMustWaitAndShortStableBoundaryPauses() {
        var gate = ScrollResponseGate()
        gate.didScroll(expectedPixels: 232)
        XCTAssertEqual(gate.evaluate(offset: 0), .accept)
        XCTAssertEqual(gate.evaluate(offset: 116), .wait)
        XCTAssertEqual(gate.evaluate(offset: 116), .wait)
        XCTAssertEqual(gate.evaluate(offset: 232), .accept)
        gate.didScroll(expectedPixels: 232)
        XCTAssertEqual(gate.evaluate(offset: 40), .wait)
        XCTAssertEqual(gate.evaluate(offset: 40), .wait)
        XCTAssertEqual(gate.evaluate(offset: 40), .acceptAndPause)
        gate.didScroll(expectedPixels: 232)
        XCTAssertEqual(gate.evaluate(offset: 40), .wait)
        XCTAssertEqual(gate.evaluate(offset: 80), .wait)
        XCTAssertEqual(gate.evaluate(offset: 120), .wait)
        XCTAssertEqual(gate.evaluate(offset: 232), .accept)
    }
    func testShortResponseSettlesDespitePixelRounding() {
        var gate = ScrollResponseGate()
        gate.didScroll(expectedPixels: 232)
        XCTAssertEqual(gate.evaluate(offset: 40), .wait)
        XCTAssertEqual(gate.evaluate(offset: 42), .wait)
        XCTAssertEqual(gate.evaluate(offset: 41), .acceptAndPause)
    }
    func testShortResponseDoesNotAccumulateToleranceAcrossDrift() {
        var gate = ScrollResponseGate()
        gate.didScroll(expectedPixels: 232)
        for offset in [40, 44, 48, 52, 56] {
            XCTAssertEqual(gate.evaluate(offset: offset), .wait)
        }
        XCTAssertEqual(gate.evaluate(offset: 56), .wait)
        XCTAssertEqual(gate.evaluate(offset: 56), .acceptAndPause)
    }
    func testMissingOrStationaryResponseBreaksSettlingSequence() {
        let interruptions: [Int?] = [nil, 0]
        for interruption in interruptions {
            var gate = ScrollResponseGate()
            gate.didScroll(expectedPixels: 232)
            XCTAssertEqual(gate.evaluate(offset: 40), .wait)
            XCTAssertEqual(gate.evaluate(offset: 41), .wait)
            XCTAssertEqual(gate.evaluate(offset: interruption), .accept)
            XCTAssertEqual(gate.evaluate(offset: 40), .wait)
            XCTAssertEqual(gate.evaluate(offset: 41), .wait)
            XCTAssertEqual(gate.evaluate(offset: 40), .acceptAndPause)
        }
    }
    func testNewWheelDiscardsPreviousSettlingSequence() {
        var gate = ScrollResponseGate()
        gate.didScroll(expectedPixels: 232)
        XCTAssertEqual(gate.evaluate(offset: 40), .wait)
        XCTAssertEqual(gate.evaluate(offset: 41), .wait)
        gate.didScroll(expectedPixels: 232)
        XCTAssertEqual(gate.evaluate(offset: 40), .wait)
        XCTAssertEqual(gate.evaluate(offset: 41), .wait)
        XCTAssertEqual(gate.evaluate(offset: 40), .acceptAndPause)
    }
    func testUnacknowledgedWheelCannotBeRepeatedByZeroFramesOrSpeedReset() {
        var progress = ScrollCaptureProgress()
        XCTAssertTrue(progress.shouldScroll)
        progress.didScroll()
        for _ in 0..<5 { progress.observe(0); XCTAssertFalse(progress.shouldScroll) }
        progress.resetCounters()
        XCTAssertFalse(progress.shouldScroll)
        progress.observe(nil)
        XCTAssertFalse(progress.shouldScroll)
        progress.observe(113)
        XCTAssertTrue(progress.shouldScroll)
    }
    func testBroadMotionIsUnstableWhileLocalAnimationIsLocated() throws {
        let page = WorkflowCorpus.texture(width: 400, height: 1000, seed: 42)
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 600)))
        let next = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 113, width: 400, height: 600)))
        XCTAssertTrue(ScrollFrameStability.compare(first, first).stable)
        XCTAssertFalse(ScrollFrameStability.compare(first, next).stable)
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(first, in: CGRect(x: 0, y: 0, width: 400, height: 600))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 560, width: 40, height: 40))
        let result = ScrollFrameStability.compare(first, try XCTUnwrap(context.makeImage()))
        XCTAssertTrue(result.stable)
        XCTAssertFalse(result.regions.isEmpty)
        XCTAssertTrue(result.regions.allSatisfy { $0.minX < 0.25 && $0.minY < 0.25 })
        let wrongSize = WorkflowCorpus.texture(width: 401, height: 600, seed: 42)
        XCTAssertFalse(ScrollFrameStability.compare(first, wrongSize).stable)
    }
}
