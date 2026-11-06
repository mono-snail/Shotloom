import AppIntents
import AppKit

struct OpenDeskCaptureWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Local Screenshot Workflow"
    static let description = IntentDescription("Open the visible workflow editor, optionally specifying a saved workflow ID.")
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Workflow ID (Optional)") var workflowID: String?
    @MainActor func perform() async throws -> some IntentResult {
        let id: UUID?
        if let text = workflowID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = UUID(uuidString: text) else { throw CaptureError.message(L10n.text("工作流ID必须是完整UUID。")) }
            id = parsed
        } else { id = nil }
        guard let coordinator = (NSApplication.shared.delegate as? ApplicationDelegate)?.coordinator else { throw CaptureError.message(L10n.text("应用尚未完成启动，请稍后重试。")) }
        try await coordinator.openWorkflow(id: id)
        return .result()
    }
}
struct DeskCaptureAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenDeskCaptureWorkflowIntent(), phrases: ["Open \(.applicationName) workflow"], shortTitle: "Open Workflow", systemImageName: "gearshape.2")
    }
}
