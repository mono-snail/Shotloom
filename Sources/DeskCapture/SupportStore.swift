import Combine
import Foundation

@MainActor
final class ShotloomSupportStore: ObservableObject {
    @Published var draft = ShotloomFeedbackDraft()
    @Published var reply = ""
    @Published private(set) var threads: [ShotloomSupportThread] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var conversation: ShotloomSupportConversation?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var receiptMessage: String?
    @Published private(set) var submissionUncertain = false
    @Published private(set) var replyUncertain = false
    @Published private(set) var needsSave = false
    @Published private(set) var loaded = false
    private var replyDrafts: [String: String] = [:]
    private var pendingThread: ShotloomSupportThread?
    private var replyBaseline = Set<String>()
    private var pendingReply: String?
    private let client: ShotloomSupportClient
    private let persistence: ShotloomSupportPersistence

    init(client: ShotloomSupportClient = ShotloomSupportClient(), persistence: ShotloomSupportPersistence = ShotloomSupportKeychain()) {
        self.client = client
        self.persistence = persistence
    }
    var selectedThread: ShotloomSupportThread? { threads.first { $0.id == selectedID } }
    var canSubmit: Bool { loaded && draft.isValid && !isBusy && !submissionUncertain && !needsSave }
    var canReply: Bool { conversation != nil && !isBusy && !replyUncertain && (1...5_000).contains(reply.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) }

    func load() async {
        guard !loaded, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { threads = try await persistence.load(); loaded = true; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    func newFeedback() {
        guard !isBusy, !needsSave, !replyUncertain else { return }
        if let selectedID { replyDrafts[selectedID] = reply }
        selectedID = nil; conversation = nil; reply = ""
        receiptMessage = nil
        errorMessage = submissionUncertain ? ShotloomSupportError.uncertainSubmission.localizedDescription : nil
        // An uncertain POST cannot be repeated just by reopening the form.
    }
    func submit() async {
        guard canSubmit else { return }
        isBusy = true; errorMessage = nil; receiptMessage = nil
        defer { isBusy = false }
        do {
            pendingThread = try await client.submit(draft)
            receiptMessage = L10n.translate("Feedback submitted")
            needsSave = true
            try await persistPendingThread()
            await refreshSelected()
        } catch {
            if case ShotloomSupportError.uncertainSubmission = error { submissionUncertain = true }
            errorMessage = error.localizedDescription
        }
    }
    func retrySave() async {
        guard needsSave, !isBusy else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await persistPendingThread(); await refreshSelected() }
        catch { errorMessage = error.localizedDescription }
    }
    private func persistPendingThread() async throws {
        guard let pendingThread else { return }
        let updated = [pendingThread] + threads.filter { $0.id != pendingThread.id }
        try await persistence.save(updated)
        threads = updated; selectedID = pendingThread.id
        self.pendingThread = nil; needsSave = false
        let email = draft.email
        let context = draft.context
        draft = ShotloomFeedbackDraft(context: context)
        draft.email = email
    }
    func select(_ id: String) async {
        guard !isBusy, !needsSave else { return }
        receiptMessage = nil
        if selectedID != id {
            // Resolve an ambiguous reply in its own thread before switching.
            guard !replyUncertain else { return }
            if let selectedID { replyDrafts[selectedID] = reply }
            selectedID = id; conversation = nil; reply = replyDrafts[id] ?? ""; pendingReply = nil
        }
        await refresh()
    }
    func refresh() async {
        guard !isBusy else { return }
        guard selectedThread != nil else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        await refreshSelected()
    }
    private func refreshSelected() async {
        guard let thread = selectedThread else { return }
        do {
            let value = try await client.conversation(thread)
            conversation = value
            if let pendingReply, value.messages.contains(where: { !replyBaseline.contains($0.id) && $0.author == "user" && $0.body == pendingReply }) {
                reply = ""; replyUncertain = false; self.pendingReply = nil
            }
            if replyUncertain { errorMessage = ShotloomSupportError.uncertainReply.localizedDescription }
        } catch { errorMessage = error.localizedDescription }
    }
    func sendReply() async {
        guard canReply, let thread = selectedThread else { return }
        isBusy = true; errorMessage = nil; receiptMessage = nil
        defer { isBusy = false }
        let message = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        replyBaseline = Set(conversation?.messages.map(\.id) ?? [])
        do {
            try await client.reply(message, to: thread)
            receiptMessage = L10n.translate("Reply sent")
            reply = ""; replyDrafts[thread.id] = nil; pendingReply = nil
            await refreshSelected()
        } catch {
            if case ShotloomSupportError.uncertainReply = error {
                replyUncertain = true; pendingReply = message
            }
            errorMessage = error.localizedDescription
        }
    }
    func acknowledgeUnconfirmedReply() {
        guard !isBusy else { return }
        replyUncertain = false; pendingReply = nil; reply = ""; errorMessage = nil
    }
    func acknowledgeUnconfirmedSubmission() {
        guard !isBusy else { return }
        submissionUncertain = false; draft = ShotloomFeedbackDraft(); errorMessage = nil
    }
}
