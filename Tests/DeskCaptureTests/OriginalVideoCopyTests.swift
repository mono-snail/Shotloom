import XCTest
@testable import DeskCapture

final class OriginalVideoCopyTests: XCTestCase {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-owned-copy-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testChunkedCopyReplacesOnlyAfterCompleteAndLeavesNoStage() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.mp4"), output = root.appendingPathComponent("destination.mp4")
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) }); try bytes.write(to: input)
        let sentinel = Data("existing destination".utf8); try sentinel.write(to: output)
        var chunks = 0
        try OriginalVideoCopy.copy(input, to: output) {
            chunks += 1; XCTAssertEqual(try Data(contentsOf: output), sentinel)
        }
        XCTAssertEqual(chunks, 3); XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
    func testMidCopyCancellationPreservesBothFilesAndRemovesStage() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.mp4"), output = root.appendingPathComponent("destination.mp4")
        let bytes = Data(repeating: 13, count: 3_000_000), sentinel = Data("keep destination".utf8)
        try bytes.write(to: input); try sentinel.write(to: output)
        let task = Task.detached {
            try OriginalVideoCopy.copy(input, to: output) { withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { try await task.value; XCTFail("Cancelled copy committed") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: input), bytes); XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
    func testSourceReplacementDuringCopyRejectsCommit() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.mp4"), output = root.appendingPathComponent("destination.mp4")
        try Data(repeating: 13, count: 3_000_000).write(to: input)
        let sentinel = Data("keep destination".utf8); try sentinel.write(to: output)
        var changed = false
        XCTAssertThrowsError(try OriginalVideoCopy.copy(input, to: output) {
            if !changed { changed = true; try Data("replaced source".utf8).write(to: input, options: .atomic) }
        })
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
    func testAliasesAndFailedCommitKeepOriginalDestination() throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.mp4"), alias = root.appendingPathComponent("alias.mp4")
        let data = Data("owned source".utf8); try data.write(to: input)
        try FileManager.default.linkItem(at: input, to: alias)
        XCTAssertThrowsError(try OriginalVideoCopy.copy(input, to: input))
        XCTAssertThrowsError(try OriginalVideoCopy.copy(input, to: alias))
        let directory = root.appendingPathComponent("existing-folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let keep = directory.appendingPathComponent("keep"); try data.write(to: keep)
        XCTAssertThrowsError(try OriginalVideoCopy.copy(input, to: directory))
        XCTAssertEqual(try Data(contentsOf: input), data); XCTAssertEqual(try Data(contentsOf: alias), data)
        XCTAssertEqual(try Data(contentsOf: keep), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
    }
}
