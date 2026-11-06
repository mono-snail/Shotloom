// Seeds generated QA fixtures in an isolated home, then exits. The production
// signed app reads the same temporary history for native menu/entry-point QA.
import AppKit

@main enum LocalImagePreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.hasPrefix("/tmp/deskcapture-") == true else {
            throw CaptureError.message("QA fixture seeding requires an isolated /tmp/deskcapture- home.")
        }
        let app = AppCoordinator()
        let fixture = try QualityDiagnostics.cleanupFixture()
        _ = try await app.store.addAsync(fixture, mode: .region)
        try CaptureImageExport.png(fixture, to: app.store.directory.appendingPathComponent("cleanup-fixture.png"))
        print("Generated fixture history: \(app.store.directory.path)")
    }
}
