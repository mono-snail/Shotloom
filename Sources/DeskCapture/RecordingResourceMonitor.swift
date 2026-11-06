import Foundation
import Darwin

struct RecordingResourceSample: Codable, Sendable {
    let seconds: Double
    let residentBytes: UInt64
    let cpuSeconds: Double
    let thermalState: Int
    let phase: String
}
struct RecordingResourceTrend: Codable, Sendable {
    let samples: Int
    let observedSeconds: Double
    let peakResidentMiB: Double
    let residentSlopeMiBPerMinute: Double?
    let averageProcessCPUPercent: Double?
    static func summarize(_ samples: [RecordingResourceSample], warmup: Double = 120) -> Self {
        let valid = samples.filter { $0.seconds.isFinite && $0.cpuSeconds.isFinite && $0.seconds >= 0 }
        let stable = valid.filter { $0.seconds >= warmup && $0.phase == "recording" }
        var slope: Double?
        if let first = stable.first, let last = stable.last, stable.count >= 3, last.seconds - first.seconds >= 60 {
            let meanX = stable.reduce(0) { $0 + $1.seconds } / Double(stable.count)
            let meanY = stable.reduce(0) { $0 + Double($1.residentBytes) / 1_048_576 } / Double(stable.count)
            let denominator = stable.reduce(0) { $0 + pow($1.seconds - meanX, 2) }
            if denominator > 0 { slope = stable.reduce(0) { $0 + ($1.seconds - meanX) * (Double($1.residentBytes) / 1_048_576 - meanY) } / denominator * 60 }
        }
        let span = max(0, (valid.last?.seconds ?? 0) - (valid.first?.seconds ?? 0))
        let cpu = span > 0 ? max(0, (valid.last?.cpuSeconds ?? 0) - (valid.first?.cpuSeconds ?? 0)) / span * 100 : nil
        return .init(samples: valid.count, observedSeconds: span, peakResidentMiB: Double(valid.map(\.residentBytes).max() ?? 0) / 1_048_576,
                     residentSlopeMiBPerMinute: slope, averageProcessCPUPercent: cpu)
    }
}
/// Explicit diagnostics only. Samples this process, excluding codecs running in
/// OS services and helper processes. CPU percentages can exceed 100 on many cores.
final class RecordingResourceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deskcapture.recording-resources", qos: .utility)
    private let started = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?
    private var samples: [RecordingResourceSample] = []
    private var phase = "preparing"
    private var finished = false
    private let trace: URL
    private var failure: Error?
    init(directory: URL) { trace = directory.appendingPathComponent("recording-resource-samples.jsonl") }
    func start() { queue.async { [self] in
        guard self.timer == nil, !self.finished else { return }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in self?.sample() }; self.timer = timer; timer.resume()
    } }
    func setPhase(_ phase: String) { queue.async { self.phase = phase } }
    private func sample() {
        guard !finished, samples.count < 7200 else { return }
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        var usage = rusage()
        guard status == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0 else { failure = CaptureError.message(L10n.text("无法读取本进程资源计数。")); return }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let row = RecordingResourceSample(seconds: ProcessInfo.processInfo.systemUptime - started, residentBytes: info.resident_size,
                                          cpuSeconds: cpu, thermalState: ProcessInfo.processInfo.thermalState.rawValue, phase: phase)
        samples.append(row)
        do {
            if !FileManager.default.fileExists(atPath: trace.path) { FileManager.default.createFile(atPath: trace.path, contents: nil) }
            let file = try FileHandle(forWritingTo: trace); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: JSONEncoder().encode(row) + Data([10]))
        } catch { failure = error }
    }
    func finish() async throws -> RecordingResourceTrend {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            self.sample(); self.finished = true; self.timer?.cancel(); self.timer = nil
            if let error = self.failure { continuation.resume(throwing: error) }
            else { continuation.resume(returning: .summarize(self.samples)) }
        } }
    }
    deinit { timer?.cancel() }
}
