import XCTest
@testable import DeskCapture

final class SidecarBudgetTests: XCTestCase {
    func testMissingRegularOversizedAndSymlinkSidecars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-sidecar-budget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data.json")
        XCTAssertNil(try RecordingEditStore.sidecarData(file))
        let data = Data("small".utf8)
        try data.write(to: file)
        XCTAssertEqual(try RecordingEditStore.sidecarData(file, maximumBytes: 5), data)
        XCTAssertThrowsError(try RecordingEditStore.sidecarData(file, maximumBytes: 4))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try RecordingEditStore.sidecarData(link))
        XCTAssertThrowsError(try RecordingEditStore.sidecarData(root))
    }
    func testLegacyLoadersRejectOversizedSparseFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-sidecar-legacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("fixture.mp4")
        for file in [VideoTranscript.url(for: video), RecordingStudioProject.url(for: video), RecordingDrawingTimeline.url(for: video)] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 20_000_001); try handle.close()
        }
        XCTAssertTrue(VideoTranscript.load(video).isEmpty)
        XCTAssertTrue(RecordingStudioProject.load(video).lenses.isEmpty)
        XCTAssertNil(RecordingDrawingTimeline.load(video))
    }
}
