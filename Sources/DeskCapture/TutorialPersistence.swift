import Foundation
import Darwin

enum TutorialPersistence {
    static func data(_ directory: URL) throws -> Data? {
        let file = directory.appendingPathComponent("steps.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_000_000 else { throw CaptureError.message(L10n.text("教程索引类型或大小无效。")) }
        return try Data(contentsOf: file)
    }
    static func save(_ steps: [TutorialStep], directory: URL, expected: Data?) throws -> Data {
        try TutorialEditing.validate(steps, allowEmpty: true)
        let bytes = try JSONEncoder().encode(steps)
        let fd = open(directory.appendingPathComponent(".steps.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CaptureError.message(L10n.text("无法打开教程保存锁。")) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CaptureError.message(L10n.text("另一进程正在保存教程。")) }
        defer { flock(fd, LOCK_UN) }
        guard try data(directory) == expected else { throw CaptureError.message(L10n.text("磁盘教程已改变，未覆盖。请重开工程后合并。")) }
        try Task.checkCancellation(); try bytes.write(to: directory.appendingPathComponent("steps.json"), options: .atomic)
        return bytes
    }
    static func recent(_ root: URL) -> (URL, [TutorialStep], Data)? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]),
              let recent = entries.filter({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("steps.json").path) }).max(by: {
                  ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
              }), let data = try? data(recent), let steps = try? JSONDecoder().decode([TutorialStep].self, from: data),
              (try? TutorialEditing.validate(steps, allowEmpty: true)) != nil else { return nil }
        return (recent, steps, data)
    }
}
