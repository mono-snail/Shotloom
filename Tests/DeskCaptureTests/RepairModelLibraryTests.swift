import XCTest
import CryptoKit
@testable import DeskCapture

final class RepairModelLibraryTests: XCTestCase {
    func testPinnedRealModelCompositeCancellationAndReuseWhenFixtureIsAvailable() async throws {
        guard let path = ProcessInfo.processInfo.environment["DESKCAPTURE_REPAIR_MODEL_FIXTURE"] else {
            throw XCTSkip("Pinned real model fixture unavailable; no inference claim")
        }
        let source = URL(fileURLWithPath: path)
        try await Task.detached {
            let files = [("Data/com.apple.CoreML/model.mlmodel", "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953"),
                         ("Data/com.apple.CoreML/weights/weight.bin", "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184")]
            for (name, expected) in files {
                let handle = try FileHandle(forReadingFrom: source.appendingPathComponent(name)); defer { try? handle.close() }
                var hash = SHA256()
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                    throw CaptureError.message("Real repair fixture hash mismatch")
                }
            }
        }.value
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repair-model-real-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = RepairModelLibrary(root: root)
        let item = try await library.importModel(from: source, provenance: "Pinned public test fixture; not redistributed")
        XCTAssertEqual(item.width, 800); XCTAssertEqual(item.height, 800)
        let width = 256, height = 192
        let base = WorkflowCorpus.texture(width: width, height: height, seed: 83), before = base.dataProvider!.data! as Data
        let selection = RepairSelection(strokes: [.init(points: [.init(x: 0.6, y: 0.3)], diameter: 48, erase: false)], feather: 2)
        let mask = try selection.raster(width: width, height: height)
        for context in RepairModelContext.allCases {
            let output = try await LocalImageRepair.render(base: base, original: base, selection: selection, method: .model, anchor: nil, modelID: item.id, library: library, modelContext: context)
            let after = output.dataProvider!.data! as Data
            var changesOutside = 0
            for y in 0..<height { for x in 0..<width where mask.values[y * width + x] == 0 {
                for c in 0..<4 where before[y * base.bytesPerRow + x * 4 + c] != after[y * output.bytesPerRow + x * 4 + c] { changesOutside += 1 }
            } }
            XCTAssertEqual(changesOutside, 0, context.rawValue)
            XCTAssertEqual(base.dataProvider!.data! as Data, before, context.rawValue)
        }
        let prediction = Task { try await library.infer(image: base, mask: mask.image!, using: item.id) }
        var observed = false
        for _ in 0..<1000 {
            if await library.activeModel == item.id { observed = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard observed else { _ = try await prediction.value; return XCTFail("No active native prediction was observed") }
        do { _ = try await library.importModel(from: source, provenance: "Must not overlap"); XCTFail("Import overlapped inference") } catch { }
        prediction.cancel()
        do { _ = try await prediction.value; XCTFail("Cancelled inference delivered pixels") } catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
        let active = await library.activeModel; XCTAssertNil(active)
        let retained = try await library.list(); XCTAssertEqual(retained.map(\.id), [item.id])
        let resumed = try await library.infer(image: base, mask: mask.image!, using: item.id)
        XCTAssertEqual(resumed.width, 800); XCTAssertEqual(resumed.height, 800)
    }
    func testInvalidModelDoesNotReplaceExistingFiles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("repair-model-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let input=root.appendingPathComponent("invalid.mlmodel");try Data("not a Core ML model".utf8).write(to:input)
        let library=RepairModelLibrary(root:root.appendingPathComponent("owned"))
        do { _=try await library.importModel(from:input,provenance:"test fixture");XCTFail("Invalid model accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf:input),Data("not a Core ML model".utf8))
        let entries=try await library.list();XCTAssertTrue(entries.isEmpty)
    }
    func testModelFileValidationRejectsLinksAndOversizedWeights() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("repair-model-links-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let target=root.appendingPathComponent("original");try Data([1,2,3]).write(to:target)
        let link=root.appendingPathComponent("linked.mlmodelc")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertThrowsError(try RepairModelLibrary.checkedSize(link))
        let large=root.appendingPathComponent("large.mlmodel");FileManager.default.createFile(atPath:large.path,contents:nil)
        let file=try FileHandle(forWritingTo:large);try file.truncate(atOffset:1_500_000_001);try file.close()
        XCTAssertThrowsError(try RepairModelLibrary.checkedSize(large))
        XCTAssertEqual(try Data(contentsOf:target),Data([1,2,3]))
    }
}
