import XCTest
import AppKit
import CoreText
@testable import DeskCapture

final class WorkflowSensitiveReviewTests: XCTestCase {
    func testNativeOCRSpacingCandidateMasksOnlySensitiveRowAndKeepsPublicRows() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 4800,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        for (index, text) in ["PUBLIC WORKFLOW TEST", "qa@example.invalid", "KEEP THIS LINE"].enumerated() {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 36, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 60, y: 460 - index * 150)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        let source = try XCTUnwrap(context.makeImage()), original = source.dataProvider!.data! as Data
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .sensitiveReview), .init(kind: .ocr)]
        let output = try await LocalWorkflowProcessor.run(source, recipe: recipe, review: { request in
            XCTAssertEqual(request.candidates.count, 1)
            XCTAssertTrue(request.candidates.first?.kinds.contains(.email) == true)
            return request.candidates.map(\.line.bounds)
        })
        XCTAssertEqual(output.text, "PUBLIC WORKFLOW TEST\nKEEP THIS LINE")
        XCTAssertEqual(source.dataProvider!.data! as Data, original)
    }
    func testReviewMustFollowAllImageStepsAndCannotBeRepeated() throws {
        let invalid: [[LocalWorkflowStep]] = [
            [.init(kind: .sensitiveReview), .init(kind: .rotate, value: 1)],
            [.init(kind: .sensitiveReview), .init(kind: .sensitiveReview)],
            [.init(kind: .ocr), .init(kind: .sensitiveReview)],
            [.init(kind: .sensitiveReview, value: 1)]
        ]
        for steps in invalid {
            var recipe = LocalWorkflowRecipe(); recipe.steps = steps
            XCTAssertThrowsError(try recipe.validate())
        }
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [.init(kind: .resize, value: 100), .init(kind: .sensitiveReview), .init(kind: .ocr)]
        try recipe.validate()
        let restored = try LocalWorkflowLibrary.decode(LocalWorkflowLibrary.encode(recipe))
        XCTAssertEqual(restored.steps, recipe.steps)
    }
    func testNoVisibleReviewerRefusesDeliverableBeforeScanning() async throws {
        let source = WorkflowCorpus.texture(width: 80, height: 40, seed: 70)
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .sensitiveReview)]
        do {
            _ = try await LocalWorkflowProcessor.run(source, recipe: recipe, reviewScanner: { _, _ in
                XCTFail("Unattended review must be rejected before OCR or rule scanning")
                return []
            })
            XCTFail("Workflow bypassed human review")
        } catch { }
    }
    func testConfirmedBoundsFlattenProcessedImageAndKeepSourceBytes() async throws {
        let source = WorkflowCorpus.texture(width: 80, height: 40, seed: 71)
        let original = source.dataProvider!.data! as Data
        var recipe = LocalWorkflowRecipe()
        recipe.steps = [.init(kind: .resize, value: 16), .init(kind: .sensitiveReview)]
        let rule = SensitiveRule(title: "Order", pattern: "order")
        let output = try await LocalWorkflowProcessor.run(source, recipe: recipe, rules: [rule], review: { request in
            XCTAssertEqual(request.image.width, 16); XCTAssertEqual(request.image.height, 8)
            XCTAssertEqual(request.candidates.count, 1)
            XCTAssertEqual(request.candidates.first?.ruleNames, ["Order"])
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        }, reviewScanner: { _, rules in
            try SensitiveRuleEvaluation.classify([OCRLine(text: "order 123", bounds: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1)],
                                                 kinds: [], rules: rules, scope: .images)
        })
        XCTAssertEqual(output.completedSteps, 2); XCTAssertNil(output.text)
        XCTAssertEqual(source.dataProvider!.data! as Data, original)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(output.image, in: CGRect(x: 0, y: 0, width: 16, height: 8))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: 512, by: 4) {
            XCTAssertEqual(bytes[offset], 0); XCTAssertEqual(bytes[offset + 1], 0)
            XCTAssertEqual(bytes[offset + 2], 0); XCTAssertEqual(bytes[offset + 3], 255)
        }
    }
    func testOCRAfterReviewDoesNotReturnOriginalSensitiveText() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 128, bitsPerComponent: 8, bytesPerRow: 2560,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 128))
        let string = NSAttributedString(string: "private@example.com", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor
        ])
        context.textPosition = CGPoint(x: 20, y: 48); CTLineDraw(CTLineCreateWithAttributedString(string), context)
        let source = try XCTUnwrap(context.makeImage()), original = source.dataProvider!.data! as Data
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .sensitiveReview), .init(kind: .ocr)]
        let output = try await LocalWorkflowProcessor.run(source, recipe: recipe, review: { request in
            XCTAssertTrue(request.candidates.contains { $0.kinds.contains(.email) }, "Real OCR fixture must produce a sensitive candidate")
            return [CGRect(x: 0, y: 0, width: 1, height: 1)]
        })
        XCTAssertEqual(output.text, ""); XCTAssertEqual(output.completedSteps, 2)
        XCTAssertEqual(source.dataProvider!.data! as Data, original)
    }
    @MainActor
    func testPendingReviewCannotDeliverAndCancelledIdentityCannotConfirmNextRun() async throws {
        let source = WorkflowCorpus.texture(width: 80, height: 40, seed: 72), run = LocalWorkflowRun(source: source)
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .sensitiveReview)]
        run.execute(recipe, reviewScanner: { _, _ in [] })
        for _ in 0..<400 where run.reviewInput == nil && run.busy { try await Task.sleep(for: .milliseconds(5)) }
        let first = try XCTUnwrap(run.reviewInput)
        XCTAssertTrue(run.busy); XCTAssertNil(run.result)
        run.confirmReview(first.id, bounds: [], reviewed: false)
        XCTAssertNotNil(run.reviewInput); XCTAssertNil(run.result)
        run.cancel()
        XCTAssertNil(run.reviewInput); XCTAssertFalse(run.busy); XCTAssertNil(run.result)
        XCTAssertTrue(run.source === source)
        run.execute(recipe, reviewScanner: { _, _ in [] })
        for _ in 0..<400 where run.reviewInput == nil && run.busy { try await Task.sleep(for: .milliseconds(5)) }
        let second = try XCTUnwrap(run.reviewInput)
        XCTAssertNotEqual(first.id, second.id)
        run.confirmReview(first.id, bounds: [], reviewed: true)
        XCTAssertEqual(run.reviewInput?.id, second.id); XCTAssertNil(run.result)
        run.confirmReview(second.id, bounds: [CGRect(x: 0, y: 0, width: 1, height: 1)], reviewed: true)
        for _ in 0..<400 where run.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(run.busy); XCTAssertNotNil(run.result); XCTAssertNil(run.reviewInput)
        XCTAssertTrue(run.source === source)
    }
    @MainActor
    func testEditingDuringReviewRejectsStaleConfirmationAndClearsDelivery() async throws {
        let source = WorkflowCorpus.texture(width: 80, height: 40, seed: 73), run = LocalWorkflowRun(source: source)
        var recipe = LocalWorkflowRecipe(); recipe.steps = [.init(kind: .sensitiveReview)]
        run.execute(recipe, reviewScanner: { _, _ in [] })
        for _ in 0..<400 where run.reviewInput == nil && run.busy { try await Task.sleep(for: .milliseconds(5)) }
        let input = try XCTUnwrap(run.reviewInput)
        run.changed(); run.confirmReview(input.id, bounds: [], reviewed: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(run.busy); XCTAssertNil(run.result); XCTAssertNil(run.reviewInput)
        XCTAssertTrue(run.source === source)
    }
}
