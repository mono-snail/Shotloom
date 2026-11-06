import XCTest
@testable import DeskCapture

final class RecordingResourceTests: XCTestCase {
    private func sample(_ seconds: Double, _ mib: Double, phase: String = "recording") -> RecordingResourceSample {
        .init(seconds: seconds, residentBytes: UInt64(mib * 1_048_576), cpuSeconds: seconds * 1.5, thermalState: 0, phase: phase)
    }
    func testTrendIgnoresWarmupAndSaveAllocation() {
        var rows = [sample(0, 100), sample(60, 400)]
        rows += stride(from: 120.0, through: 600, by: 60).map { sample($0, 450) }
        rows += [sample(660, 900, phase: "saving")]
        let result = RecordingResourceTrend.summarize(rows)
        XCTAssertEqual(result.peakResidentMiB, 900)
        XCTAssertEqual(result.residentSlopeMiBPerMinute ?? .nan, 0, accuracy: 0.0001)
        XCTAssertEqual(result.averageProcessCPUPercent ?? .nan, 150, accuracy: 0.0001)
    }
    func testLinearGrowthHasMeasuredSlope() {
        let rows = stride(from: 120.0, through: 1800, by: 5).map { sample($0, 200 + $0 / 60 * 2) }
        let result = RecordingResourceTrend.summarize(rows)
        XCTAssertEqual(result.residentSlopeMiBPerMinute ?? .nan, 2, accuracy: 0.0001)
        XCTAssertEqual(result.observedSeconds, 1680)
    }
    func testShortObservationDoesNotPretendToMeasureLongTermGrowth() {
        let result = RecordingResourceTrend.summarize([sample(0, 100), sample(5, 110), sample(10, 100)])
        XCTAssertNil(result.residentSlopeMiBPerMinute)
        XCTAssertEqual(result.samples, 3)
    }
    func testResourceTraceUsesTemporaryArtifactsAndFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeskCapture-resource-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let monitor = RecordingResourceMonitor(directory: directory)
        monitor.start(); monitor.setPhase("recording")
        let result = try await monitor.finish()
        XCTAssertGreaterThan(result.samples, 0)
        XCTAssertGreaterThan(result.peakResidentMiB, 0)
        let data = try Data(contentsOf: directory.appendingPathComponent("recording-resource-samples.jsonl"))
        for line in data.split(separator: 10) { _ = try JSONDecoder().decode(RecordingResourceSample.self, from: Data(line)) }
    }
}
