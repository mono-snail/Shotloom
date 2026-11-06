import XCTest
import AppKit
import SwiftUI
@testable import DeskCapture

final class CaptureTests: XCTestCase {
    @MainActor
    func testSessionEscapeClosesAllPanelsWithTextFieldFocusedAndCancelsOnlyOnce() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let session = SelectionSession(snapshots: [ScreenSnapshot(screen: screen, image: makeImage())], windows: [], mode: .region)
        defer { session.close() }
        var cancellations = 0
        session.onCancel = { cancellations += 1 }
        session.show()
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? CapturePanel }.first { $0.isVisible })
        let field = NSTextField(frame: CGRect(x: 20, y: 20, width: 200, height: 30))
        try XCTUnwrap(panel.contentView).addSubview(field)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(session.handleEscape(enter))
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(session.handleEscape(escape))
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(session.handleEscape(escape))
        session.cancel()
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testDraggingEmptySpaceInAnnotationSelectionModeDoesNotResizeRegion() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: makeImage()), mode: .region, windows: [])
        view.setInitialSelectionForPreview(CGRect(x: 40, y: 40, width: 200, height: 160))
        let toolbar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
        toolbar.rootView.state.selectingMark = true
        let originalRect = view.selection, originalDocument = view.document
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 160, y: 150)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 160, y: 150)))
        XCTAssertEqual(view.selection, originalRect)
        XCTAssertTrue(view.document === originalDocument)
        XCTAssertFalse(toolbar.isHidden)
    }

    @MainActor
    func testRepeatedNewRegionAfterToolbarActionsAlwaysRestoresToolbar() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        // Match display coordinates: a 100px thumbnail makes the 16:9 pixel
        // alignment expand the selection over the next synthetic drag point.
        let image = makeImage(width: Int(screen.frame.width), height: Int(screen.frame.height))
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: image), mode: .region, windows: [])
        let panel = CapturePanel(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        view.setInitialSelectionForPreview(CGRect(x: 40, y: 40, width: 160, height: 120))
        view.changeAspectRatio(.landscape)
        for cycle in 0..<6 {
            let toolbar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
            let state = toolbar.rootView.state
            let oldDocument = try XCTUnwrap(view.document)
            // The annotation selection button (also used after image import) leaves this mode active.
            state.selectingMark = cycle.isMultiple(of: 2)
            state.tool = cycle.isMultiple(of: 2) ? nil : .pen
            state.liftingContent = !cycle.isMultiple(of: 2)
            state.detectedElements = [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)]
            let start = CGPoint(x: cycle.isMultiple(of: 2) ? 300 : 20, y: 20)
            let end = CGPoint(x: start.x + 160, y: start.y + 120)
            XCTAssertFalse(try XCTUnwrap(view.selection).insetBy(dx: -10, dy: -10).contains(start), "A new-region gesture must start outside the existing selection and its handles")
            view.mouseDown(with: mouse(.leftMouseDown, at: start))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
            view.mouseUp(with: mouse(.leftMouseUp, at: end))
            let replacement = try XCTUnwrap(view.document)
            XCTAssertFalse(replacement === oldDocument)
            let restored = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
            XCTAssertFalse(restored.isHidden)
            XCTAssertTrue(view.bounds.contains(restored.frame))
            XCTAssertFalse(state.selectingMark)
            XCTAssertNil(state.tool)
            XCTAssertFalse(state.liftingContent)
            XCTAssertTrue(state.detectedElements.isEmpty)
            XCTAssertEqual(state.aspectRatio, .landscape)
            XCTAssertEqual(replacement.original.width * 9, replacement.original.height * 16)
        }
    }

    @MainActor
    func testInlineColorPickerCopiesWithoutMovingOrCompletingSelection() throws {
        let board = NSPasteboard(name: .init("DeskCapture-color-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let screen = try XCTUnwrap(NSScreen.main)
        let source = makeImage()
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: source), mode: .region, windows: [], colorPasteboard: board)
        view.setInitialSelectionForPreview(CGRect(x: 20, y: 20, width: 240, height: 180))
        let toolbar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
        let doc = try XCTUnwrap(view.document)
        doc.add(doc.makeMark(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.7, y: 0.7)]))
        let rect = view.selection, markID = doc.marks.first?.id
        var completed = false, cancelled = false
        view.onComplete = { _ in completed = true }; view.onCancel = { cancelled = true }
        func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        view.keyDown(with: key(35, "p"))
        XCTAssertTrue(toolbar.rootView.state.pickingColor)
        let point = CGPoint(x: 90, y: 90)
        let expected = try XCTUnwrap(CapturePixelColor.sample(source, at: CGPoint(x: point.x / screen.frame.width * CGFloat(source.width),
            y: (screen.frame.height - point.y) / screen.frame.height * CGFloat(source.height))))
        view.mouseDown(with: mouse(.leftMouseDown, at: point, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, at: point))
        XCTAssertEqual(board.string(forType: .string), expected.hex)
        XCTAssertEqual(toolbar.rootView.state.pickedColor, expected)
        view.keyDown(with: key(48, "\t", flags: .shift))
        XCTAssertEqual(board.string(forType: .string), expected.rgb)
        XCTAssertEqual(view.selection, rect); XCTAssertEqual(view.document?.marks.first?.id, markID)
        XCTAssertFalse(completed)
        view.keyDown(with: key(35, "p"))
        XCTAssertFalse(toolbar.rootView.state.pickingColor)
        view.mouseDown(with: mouse(.leftMouseDown, at: point, clicks: 2))
        XCTAssertTrue(completed)
        toolbar.rootView.state.pickingColor = true
        toolbar.rootView.state.liftingContent = true
        view.keyDown(with: key(53))
        XCTAssertTrue(cancelled, "Esc must exit even while a capture tool is active")
    }

    @MainActor
    func testArrowKeyCannotDiscardExistingInlineAnnotations() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: makeImage()), mode: .region, windows: [])
        view.setInitialSelectionForPreview(CGRect(x: 20, y: 20, width: 240, height: 180))
        let document = try XCTUnwrap(view.document)
        document.add(document.makeMark(tool: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5)]))
        let selection = view.selection, markID = document.marks.first?.id
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        view.keyDown(with: event)
        XCTAssertEqual(view.selection, selection)
        XCTAssertEqual(view.document?.marks.first?.id, markID)
    }
    @MainActor
    func testSelectionShowsInlineToolbarAndDoubleClickCopiesWithoutCompletingOnMouseUp() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: makeImage()), mode: .region, windows: [])
        let panel = CapturePanel(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        var completed: CaptureDestination?
        view.onComplete = { completed = $0 }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 250, y: 250)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 250, y: 250)))
        XCTAssertNil(completed, "Releasing the selection must leave inline editing active")
        XCTAssertNotNil(view.document)
        XCTAssertFalse(view.subviews.isEmpty, "Toolbar appears at the selection")
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), clicks: 2))
        XCTAssertEqual(completed, .clipboard)
    }

    @MainActor
    func testEscapeCancelsAndTextModeEnterCopiesText() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: makeImage()), mode: .text, windows: [])
        let panel = CapturePanel(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        var completed: CaptureDestination?
        var cancelled = false
        view.onComplete = { completed = $0 }; view.onCancel = { cancelled = true }
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 250, y: 250)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 250, y: 250)))
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        XCTAssertEqual(completed, .text)
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!)
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testInlineVectorIconDragCreatesScalableMarkWithoutClosingSelection() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let screenshot = makeImage(width: Int(screen.frame.width), height: Int(screen.frame.height))
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: screenshot), mode: .region, windows: [])
        let panel = CapturePanel(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        view.setInitialSelectionForPreview(CGRect(x: 50, y: 50, width: 240, height: 240))
        let toolbar = try XCTUnwrap(view.subviews.compactMap { $0 as? NSHostingView<InlineCaptureToolbar> }.first)
        toolbar.rootView.state.tool = .icon
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 90, y: 90)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 160, y: 185)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 160, y: 185)))
        let document = try XCTUnwrap(view.document)
        let mark = try XCTUnwrap(document.marks.first)
        XCTAssertEqual(mark.tool, .icon)
        XCTAssertEqual(document.marks.count, 1)
        XCTAssertEqual(abs(mark.points[1].x - mark.points[0].x) * CGFloat(document.original.width),
                       abs(mark.points[1].y - mark.points[0].y) * CGFloat(document.original.height), accuracy: 1)
        XCTAssertNotNil(view.selection)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                          context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testRetinaSelectionConvertsFromBottomLeftToTopLeft() {
        let result = CaptureGeometry.pixelRect(CGRect(x: 10, y: 20, width: 80, height: 40),
                                               viewSize: CGSize(width: 200, height: 100), imageSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(result, CGRect(x: 20, y: 80, width: 160, height: 80))
    }
    func testReverseDragAndScreenEdgesAreClamped() {
        let result = CaptureGeometry.rect(from: CGPoint(x: 90, y: 70), to: CGPoint(x: -20, y: -10),
                                          in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 90, height: 70))
    }
    func testStorePersistsTextAndDeletesImageAndIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let record = try store.add(makeImage(), mode: .text)
        try store.setText("屏幕 OCR\nhello", for: record.id)
        let reloaded = CaptureStore(directory: directory)
        XCTAssertEqual(reloaded.records.count, 1)
        XCTAssertEqual(reloaded.records[0].recognizedText, "屏幕 OCR\nhello")
        XCTAssertNotNil(reloaded.image(for: record))
        try reloaded.delete(record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.url(for: record).path))
        XCTAssertTrue(CaptureStore(directory: directory).records.isEmpty)
    }
    func testMissingImageKeepsMetadataWithoutRewritingIndexAndIsUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let record = try store.add(makeImage(), mode: .region)
        let index = directory.appendingPathComponent("history.json"), bytes = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: store.url(for: record))
        let loaded = CaptureStore(directory: directory, pruneOnInit: false)
        XCTAssertEqual(loaded.records.map(\.id), [record.id])
        XCTAssertNil(loaded.image(for: record))
        XCTAssertEqual(try Data(contentsOf: index), bytes, "Loading a missing image must not erase recoverable metadata")
    }
    func testMissingRenderedImageKeepsEditableProjectAndOriginalPixels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("project-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory, pruneOnInit: false), image = makeImage()
        let document = AnnotationDocument(image: image)
        document.add(document.makeMark(tool: .rectangle, points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.5)]))
        let record = try store.add(try XCTUnwrap(document.render()), mode: .region, document: document)
        let project = try XCTUnwrap(store.projectURL(for: record)), bytes = try Data(contentsOf: project)
        try FileManager.default.removeItem(at: store.url(for: record))
        let loaded = CaptureStore(directory: directory, pruneOnInit: false)
        XCTAssertEqual(loaded.records.map(\.id), [record.id])
        let restored = try XCTUnwrap(loaded.document(for: record))
        XCTAssertEqual(restored.original.width, image.width)
        XCTAssertEqual(restored.marks.map(\.tool), document.marks.map(\.tool))
        XCTAssertEqual(restored.marks.map(\.points), document.marks.map(\.points))
        XCTAssertNotNil(restored.render()); XCTAssertEqual(try Data(contentsOf: project), bytes)
    }
    func testClearAllHistoryRemovesOriginalsProjectsTextAndPreservesOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let document = AnnotationDocument(image: makeImage())
        document.add(document.makeMark(tool: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)]))
        let first = try store.add(makeImage(), mode: .region, document: document)
        let second = try store.add(makeImage(), mode: .text)
        try store.setText("OCR history", for: second.id)
        XCTAssertNotNil(store.thumbnail(for: first))
        let export = directory.appendingPathComponent("export.png")
        try Data("exported copy".utf8).write(to: export)
        // A missing original must not prevent the rest of the history clearing.
        try FileManager.default.removeItem(at: store.url(for: second))
        let project = try XCTUnwrap(store.projectURL(for: first))
        try store.clearAll()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(CaptureStore(directory: directory).records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
        XCTAssertNil(store.thumbnail(for: first), "Deleted images must leave the thumbnail cache")
        XCTAssertEqual(try Data(contentsOf: export), Data("exported copy".utf8))
        try store.clearAll()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["export.png", "history.json"])
    }
    func testClearAllRestoresFilesAndRecordsWhenIndexCommitFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let record = try store.add(makeImage(), mode: .text)
        let imageData = try Data(contentsOf: store.url(for: record))
        let index = directory.appendingPathComponent("history.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.clearAll())
        XCTAssertEqual(store.records, [record])
        XCTAssertEqual(try Data(contentsOf: store.url(for: record)), imageData)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".clear-history-") })
    }
    func testRetentionPrunesExpiredImageAndTextIndex() throws {
        let previous = AppPreferences.standard.integer(forKey: "historyRetentionDays")
        AppPreferences.standard.set(0, forKey: "historyRetentionDays")
        defer { AppPreferences.standard.set(previous, forKey: "historyRetentionDays") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureStore(directory: directory)
        let saved = try store.add(makeImage(), mode: .region)
        try store.setText("private OCR text", for: saved.id)
        let expired = CaptureRecord(id: saved.id, createdAt: Date().addingTimeInterval(-40 * 86_400),
                                    filename: saved.filename, width: saved.width, height: saved.height,
                                    mode: saved.mode, recognizedText: "private OCR text")
        try JSONEncoder().encode([expired]).write(to: directory.appendingPathComponent("history.json"))
        AppPreferences.standard.set(30, forKey: "historyRetentionDays")
        let reloaded = CaptureStore(directory: directory)
        XCTAssertTrue(reloaded.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.url(for: expired).path))
        XCTAssertEqual(try JSONDecoder().decode([CaptureRecord].self,
                                               from: Data(contentsOf: directory.appendingPathComponent("history.json"))).count, 0)
    }
    func testRedactionChangesExportedPixelsWithoutMutatingOriginalAndUndoRestores() throws {
        let original = makeImage()
        let document = AnnotationDocument(image: original)
        document.add(Annotation(tool: .redact, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)]))
        let exported = try XCTUnwrap(document.render())
        XCTAssertLessThan(centerPixel(exported)[0], 5)
        XCTAssertGreaterThan(centerPixel(original)[0], 240)
        document.undo()
        XCTAssertGreaterThan(centerPixel(try XCTUnwrap(document.render()))[0], 240)
        document.redo()
        XCTAssertLessThan(centerPixel(try XCTUnwrap(document.render()))[0], 5)
    }
    func testAnnotationAttributesAreCapturedWhenMarkIsCreated() {
        let document = AnnotationDocument(image: makeImage())
        document.selectColor(.violet)
        document.fill = .translucent
        document.lineWidth = 11
        document.mosaicStyle = .crystal
        document.mosaicStrength = 5
        document.icon = .bolt
        let mark = document.makeMark(tool: .rectangle, points: [.zero, CGPoint(x: 1, y: 1)])
        document.selectColor(.coral); document.fill = .outline; document.lineWidth = 2
        XCTAssertEqual(mark.fill, .translucent)
        XCTAssertEqual(mark.width, 11)
        XCTAssertEqual(mark.mosaicStyle, .crystal)
        XCTAssertEqual(mark.mosaicStrength, 5)
        XCTAssertEqual(mark.icon, .bolt)
        XCTAssertEqual(mark.color, AnnotationColor.violet.color)
    }
    func testShapeFillStylesChangeExportedPixels() throws {
        var centerGreen = [AnnotationFill: UInt8]()
        for fill in AnnotationFill.allCases {
            let document = AnnotationDocument(image: makeImage())
            document.fill = fill
            document.add(document.makeMark(tool: .roundedRectangle,
                                           points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]))
            centerGreen[fill] = centerPixel(try XCTUnwrap(document.render()))[1]
        }
        XCTAssertGreaterThan(try XCTUnwrap(centerGreen[.outline]), 240)
        XCTAssertLessThan(try XCTUnwrap(centerGreen[.solid]), 150)
        XCTAssertGreaterThan(try XCTUnwrap(centerGreen[.translucent]), 150)
        XCTAssertLessThan(try XCTUnwrap(centerGreen[.translucent]), 240)
    }
    func testMosaicStylesRenderDistinctImagesAndKeepSourceUntouched() throws {
        let original = makePatternImage()
        let sourcePNG = try XCTUnwrap(NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:]))
        var fingerprints = Set<Data>()
        for style in MosaicStyle.allCases {
            let document = AnnotationDocument(image: original)
            document.mosaicStyle = style
            document.add(document.makeMark(tool: .mosaic, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)]))
            let rendered = try XCTUnwrap(document.render())
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
            fingerprints.insert(png)
        }
        XCTAssertEqual(fingerprints.count, MosaicStyle.allCases.count)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: original).representation(using: .png, properties: [:])), sourcePNG)
    }
    func testSpotlightMagnifierAndMeasureRenderOnOriginalWithoutMutatingIt() throws {
        let source = makePatternImage()
        let sourceData = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        var outputs = Set<Data>()
        for tool in [AnnotationTool.spotlight, .magnify, .measure] {
            let document = AnnotationDocument(image: source)
            document.add(document.makeMark(tool: tool, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.75, y: 0.75)]))
            let result = try XCTUnwrap(document.render())
            outputs.insert(try XCTUnwrap(NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])))
        }
        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])), sourceData)
    }
    func testVectorIconScalesToOutputResolutionAndKeepsSquareAspect() throws {
        let small = AnnotationDocument(image: makeImage())
        let large = AnnotationDocument(image: makeImage(width: 400, height: 400))
        let points = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)]
        for document in [small, large] {
            document.icon = .star
            document.add(document.makeMark(tool: .icon, points: points))
        }
        let redSmall = redPixelCount(try XCTUnwrap(small.render()))
        let redLarge = redPixelCount(try XCTUnwrap(large.render()))
        XCTAssertGreaterThan(redSmall, 100)
        XCTAssertGreaterThan(Double(redLarge) / Double(redSmall), 14)
        XCTAssertLessThan(Double(redLarge) / Double(redSmall), 18)
        let end = large.iconEnd(from: CGPoint(x: 0.2, y: 0.2), toward: CGPoint(x: 0.5, y: 0.8))
        XCTAssertEqual(end.x, end.y, accuracy: 0.001)
    }
    func testExistingMarkCanBeSelectedRestyledMovedDeletedAndUndone() throws {
        let document = AnnotationDocument(image: makeImage())
        document.add(document.makeMark(tool: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.6)]))
        document.selectMark(at: CGPoint(x: 0.4, y: 0.4), tolerance: .zero)
        XCTAssertNotNil(document.selectedMark)
        document.selectColor(.cyan); document.lineWidth = 12; document.fill = .solid
        document.changeSelectedShape(to: .ellipse)
        XCTAssertEqual(document.selectedMark?.tool, .ellipse)
        XCTAssertEqual(document.selectedMark?.width, 12)
        XCTAssertEqual(document.selectedMark?.fill, .solid)
        XCTAssertEqual(document.selectedMark?.color, AnnotationColor.cyan.color)
        let original = document.marks
        document.moveSelected(from: original, by: CGPoint(x: 0.1, y: -0.1)); document.commitMove(from: original)
        XCTAssertEqual(try XCTUnwrap(document.selectedMark).points[0].x, 0.3, accuracy: 0.0001)
        document.undo(); XCTAssertEqual(try XCTUnwrap(document.selectedMark).points[0].x, 0.2, accuracy: 0.0001)
        document.redo(); XCTAssertEqual(try XCTUnwrap(document.selectedMark).points[0].x, 0.3, accuracy: 0.0001)
        document.deleteSelected(); XCTAssertTrue(document.marks.isEmpty)
        document.undo(); XCTAssertEqual(document.marks.count, 1)
    }
    @MainActor
    func testPreciseSelectionSizeUsesImagePixels() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let image = makeImage(width: Int(screen.frame.width) * 2, height: Int(screen.frame.height) * 2)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: image), mode: .region, windows: [])
        let panel = CapturePanel(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        view.setInitialSelectionForPreview(CGRect(x: 50, y: 50, width: 200, height: 200))
        view.resizeSelection(toPixelWidth: 320, height: 240)
        XCTAssertEqual(view.document?.original.width, 320)
        XCTAssertEqual(view.document?.original.height, 240)
    }
    func testFixedRatioDragKeepsPixelRatioAcrossDirectionsAndScreenEdges() throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Also cover unequal scaling between view coordinates and image pixels.
        let scale = CGSize(width: 2, height: 1.5)
        for ratio in CaptureAspectRatio.allCases where ratio != .free {
            let units = try XCTUnwrap(ratio.units)
            for end in [CGPoint(x: 700, y: 400), CGPoint(x: -100, y: 900),
                        CGPoint(x: 1000, y: -200), CGPoint(x: -200, y: -300)] {
                let anchor = CGPoint(x: 400, y: 300)
                let rect = CaptureGeometry.rect(from: anchor, to: end, in: bounds, aspectRatio: ratio, pixelScale: scale)
                XCTAssertTrue(bounds.contains(rect))
                XCTAssertTrue(rect.minX == anchor.x || rect.maxX == anchor.x)
                XCTAssertTrue(rect.minY == anchor.y || rect.maxY == anchor.y)
                let pixels = CaptureGeometry.pixelRect(rect, viewSize: bounds.size,
                    imageSize: CGSize(width: bounds.width * scale.width, height: bounds.height * scale.height))
                XCTAssertEqual(pixels.width * units.height, pixels.height * units.width, accuracy: 0.001)
            }
        }
    }
    @MainActor
    func testFixedRatioSelectionSwitchResizeRedrawAndUnlock() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let image = makeImage(width: Int(screen.frame.width) * 2, height: Int(screen.frame.height) * 2)
        let view = SelectionView(snapshot: ScreenSnapshot(screen: screen, image: image), mode: .region, windows: [])
        let panel = CapturePanel(contentRect: CGRect(origin: .zero, size: screen.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = view
        view.setInitialSelectionForPreview(CGRect(x: 50, y: 50, width: 200, height: 200))
        func assertRatio(_ width: Int, _ height: Int) throws {
            let doc = try XCTUnwrap(view.document)
            XCTAssertEqual(doc.original.width * height, doc.original.height * width)
        }
        view.changeAspectRatio(.landscape)
        try assertRatio(16, 9)
        view.resizeSelection(toPixelWidth: 321, height: 240)
        try assertRatio(16, 9)
        let rect = try XCTUnwrap(view.selection)
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: rect.maxX, y: rect.maxY)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: screen.frame.width + 300, y: screen.frame.height + 300)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: screen.frame.width + 300, y: screen.frame.height + 300)))
        try assertRatio(16, 9)
        view.changeAspectRatio(.portrait)
        try assertRatio(9, 16)
        // Starting a fresh region retains the chosen ratio.
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 100, y: 210)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 210)))
        try assertRatio(9, 16)
        view.changeAspectRatio(.square)
        try assertRatio(1, 1)
        view.changeAspectRatio(.free)
        view.resizeSelection(toPixelWidth: 320, height: 240)
        XCTAssertEqual(view.document?.original.width, 320)
        XCTAssertEqual(view.document?.original.height, 240)
    }
    func testVideoTrimRangeRejectsInvalidTimes() throws {
        let valid = try VideoTrimmer.range(start: 1, end: 2.5, duration: 4)
        XCTAssertEqual(valid.duration.seconds, 1.5, accuracy: 0.001)
        XCTAssertThrowsError(try VideoTrimmer.range(start: 2, end: 1, duration: 4))
        XCTAssertThrowsError(try VideoTrimmer.range(start: 1, end: 5, duration: 4))
    }
    func testEditableProjectRoundTripAndHistoryDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = AnnotationDocument(image: makeImage())
        document.fill = .translucent; document.lineWidth = 10; document.selectColor(.cyan)
        document.add(document.makeMark(tool: .ellipse, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.7, y: 0.7)]))
        let store = CaptureStore(directory: directory)
        let saved = try store.add(try XCTUnwrap(document.render()), mode: .region, document: document)
        let projectURL = try XCTUnwrap(store.projectURL(for: saved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        let reloaded = CaptureStore(directory: directory)
        let restored = try XCTUnwrap(reloaded.document(for: try XCTUnwrap(reloaded.records.first)))
        XCTAssertEqual(restored.original.width, 100)
        XCTAssertEqual(restored.marks.count, 1)
        XCTAssertEqual(restored.marks[0].tool, .ellipse)
        XCTAssertEqual(restored.marks[0].fill, .translucent)
        XCTAssertEqual(restored.marks[0].width, 10)
        XCTAssertEqual(restored.marks[0].color, AnnotationColor.cyan.color)
        try reloaded.delete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
    }
    func testSensitiveSuggestionsUseOCRLocationsAndCanBeReviewedOrUndone() {
        let document = AnnotationDocument(image: makeImage())
        document.ocrLines = [
            OCRLine(text: "contact a@example.com", bounds: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1), confidence: 0.9),
            OCRLine(text: "普通说明", bounds: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.1), confidence: 0.9),
            OCRLine(text: "13800138000", bounds: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1), confidence: 0.9)
        ]
        XCTAssertEqual(document.suggestSensitiveRedactions(), 2)
        XCTAssertEqual(document.marks.count, 2)
        XCTAssertTrue(document.marks.allSatisfy { $0.tool == .redact })
        document.undo(); XCTAssertTrue(document.marks.isEmpty)
    }
    func testBackgroundStylesExpandImageWithoutChangingSource() throws {
        let source = makePatternImage()
        let original = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        var results = Set<Data>()
        for style in BeautifyStyle.allCases {
            let output = try CaptureBeautifier.render(source, style: style)
            XCTAssertGreaterThan(output.width, source.width)
            XCTAssertGreaterThan(output.height, source.height)
            results.insert(try XCTUnwrap(NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])))
        }
        XCTAssertEqual(results.count, BeautifyStyle.allCases.count)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:])), original)
    }
    private func makeImage(width: Int = 100, height: Int = 100) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    private func makePatternImage() -> CGImage {
        let context = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 480,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<12 { for column in 0..<12 {
            context.setFillColor((row + column).isMultiple(of: 2) ? NSColor.systemBlue.cgColor : NSColor.systemOrange.cgColor)
            context.fill(CGRect(x: column * 10, y: row * 10, width: 10, height: 10))
        } }
        return context.makeImage()!
    }
    private func redPixelCount(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        return data.withUnsafeBytes { bytes in
            let pixels = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: pixels.count, by: 4).filter {
                pixels[$0] > 200 && pixels[$0 + 1] < 150 && pixels[$0 + 2] < 170
            }.count
        }
    }
    private func centerPixel(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 4)
        pixels.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image.cropping(to: CGRect(x: 50, y: 50, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixels
    }
}
