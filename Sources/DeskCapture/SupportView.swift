import AppKit
import SwiftUI

/// A retained native window keeps unsent text and pending receipts across close/reopen.
@MainActor
final class ShotloomSupportWindow {
    static let shared = ShotloomSupportWindow()
    private let store = ShotloomSupportStore()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = L10n.translate("Support and Feedback")
            panel.contentMinSize = NSSize(width: 740, height: 640)
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ShotloomSupportView(store: store, close: { [weak panel] in panel?.close() }))
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ShotloomSupportView: View {
    @ObservedObject var store: ShotloomSupportStore
    let close: () -> Void
    @State private var showsContext = false
    @State private var confirmsNewFeedback = false
    @State private var confirmsNewReply = false

    var body: some View {
        StudioDialog(title: L10n.translate("Support and Feedback"), symbol: "bubble.left.and.bubble.right",
                     width: 740, height: 640) {
            HStack(alignment: .top, spacing: 20) {
                sidebar.frame(width: 164)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if store.selectedThread != nil { conversation } else { ScrollView { feedbackForm } }
                    if let receipt = store.receiptMessage {
                        Label(receipt, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.ice).accessibilityIdentifier("support.receipt")
                    }
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("support.error")
                    }
                    if !store.loaded && !store.isBusy {
                        Button(L10n.translate("Retry loading conversations")) { Task { await store.load() } }
                    }
                    if store.needsSave {
                        Button(L10n.translate("Retry saving conversation")) { Task { await store.retrySave() } }
                            .disabled(store.isBusy)
                    }
                    if store.submissionUncertain {
                        Button(L10n.translate("Start new feedback…")) { confirmsNewFeedback = true }.disabled(store.isBusy)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } actions: {
            if store.isBusy { ProgressView().controlSize(.small).accessibilityLabel(L10n.translate("Contacting support")) }
            Spacer()
            Button(L10n.translate("Close"), action: close).keyboardShortcut(.cancelAction)
            if store.selectedThread != nil {
                Button(L10n.translate("Send reply")) { Task { await store.sendReply() } }
                    .buttonStyle(StudioButtonStyle(primary: true, command: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canReply).accessibilityIdentifier("support.sendReply")
            } else {
                Button(L10n.translate("Submit feedback")) { Task { await store.submit() } }
                    .buttonStyle(StudioButtonStyle(primary: true, command: true)).keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSubmit).accessibilityIdentifier("support.submit")
            }
        }
        .task { await store.load(); await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .alert(L10n.translate("Start new feedback?"), isPresented: $confirmsNewFeedback) {
            Button(L10n.translate("Cancel"), role: .cancel) {}
            Button(L10n.translate("Start new feedback")) { store.acknowledgeUnconfirmedSubmission() }
        } message: {
            Text(L10n.translate("The previous submission may already exist. Its draft will be cleared to avoid submitting it twice."))
        }
        .alert(L10n.translate("Write a new reply?"), isPresented: $confirmsNewReply) {
            Button(L10n.translate("Cancel"), role: .cancel) {}
            Button(L10n.translate("Write a new reply")) { store.acknowledgeUnconfirmedReply() }
        } message: {
            Text(L10n.translate("The previous reply may still arrive. Its draft will be cleared to avoid sending it twice."))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button { store.newFeedback() } label: {
                Label(L10n.translate("New feedback"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(StudioButtonStyle(quiet: true, command: true))
                .keyboardShortcut("n", modifiers: .command)
                .background(store.selectedID == nil ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                .disabled(store.isBusy || store.needsSave || store.replyUncertain)
            Text(L10n.translate("Your conversations")).font(.subheadline.weight(.medium)).foregroundStyle(Palette.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.threads) { thread in
                        Button { Task { await store.select(thread.id) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(thread.title).lineLimit(2).multilineTextAlignment(.leading)
                                Text(displayDate(thread.createdAt)).font(.caption).foregroundStyle(Palette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(StudioButtonStyle(quiet: true, command: true))
                            .background(store.selectedID == thread.id ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .disabled(store.isBusy || store.needsSave || store.replyUncertain)
                    }
                    if store.loaded && store.threads.isEmpty {
                        Text(L10n.translate("No feedback yet")).foregroundStyle(Palette.muted).padding(.top, 8)
                    }
                }
            }
            Text(AppSupport.email).font(.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
        }.frame(maxHeight: .infinity)
    }

    private var feedbackForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorField(title: L10n.translate("Feedback type")) {
                Picker(L10n.translate("Feedback type"), selection: $store.draft.type) {
                    ForEach(ShotloomFeedbackType.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            InspectorField(title: L10n.translate("Title (3–160 characters)")) {
                TextField("", text: $store.draft.title).accessibilityLabel(L10n.translate("Feedback title"))
                    .accessibilityIdentifier("support.title")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.translate("Description (10–5,000 characters)")).fontWeight(.medium)
                    Spacer()
                    if !store.draft.description.isEmpty {
                        Text("\(store.draft.description.utf16.count)/5000").monospacedDigit()
                            .foregroundStyle(store.draft.description.utf16.count > 5000 ? Color.red : Palette.muted)
                    }
                }
                editor(text: $store.draft.description, label: L10n.translate("Feedback description"), height: 170)
                    .accessibilityIdentifier("support.description")
            }
            InspectorField(title: L10n.translate("Email address")) {
                TextField("", text: $store.draft.email, prompt: Text(verbatim: "name@example.com").foregroundStyle(Palette.muted))
                    .accessibilityLabel(L10n.translate("Email address")).accessibilityIdentifier("support.email")
            }
            DisclosureGroup(isExpanded: $showsContext) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.translate("Include app information"), isOn: Binding(
                        get: { store.draft.context != nil },
                        set: { store.draft.context = $0 ? .current : nil }))
                    if let context = store.draft.context {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            contextRow("Product", "Shotloom")
                            contextRow("App version", "\(context.appVersion) (\(context.build))")
                            contextRow("System", context.systemVersion)
                            contextRow("Language", context.language)
                        }.textSelection(.enabled).foregroundStyle(Palette.muted)
                    }
                }.padding(.top, 12)
            } label: { Text(L10n.translate("App information")) }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("support.validation")
            }
        }.padding(.trailing, 4).disabled(store.isBusy || store.needsSave || store.submissionUncertain || !store.loaded)
    }

    private var validationMessage: String? {
        let draft = store.draft.normalized
        if !store.draft.title.isEmpty && !(3...160).contains(draft.title.utf16.count) {
            return L10n.translate("Use 3–160 characters for the title.")
        }
        if !store.draft.description.isEmpty && !(10...5_000).contains(draft.description.utf16.count) {
            return L10n.translate("Use 10–5,000 characters for the description.")
        }
        if !store.draft.email.isEmpty && (draft.email.utf16.count > 254 ||
            draft.email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil) {
            return L10n.translate("Enter a valid email address.")
        }
        return nil
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.selectedThread?.title ?? "").font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let value = store.conversation { Text(value.feedback.statusTitle).foregroundStyle(Palette.ice) }
                }
                Spacer()
                StudioIconButton(title: L10n.translate("Refresh"), symbol: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isBusy)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(store.conversation?.messages ?? []) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(L10n.translate(message.author == "user" ? "You" : "Support team"),
                                      systemImage: message.author == "user" ? "person.crop.circle" : "bubble.left.and.bubble.right")
                                    .fontWeight(.medium).foregroundStyle(message.author == "user" ? Palette.muted : Palette.ice)
                                Spacer()
                                Text(displayDate(message.createdAt)).font(.caption).foregroundStyle(Palette.muted)
                            }
                            Text(message.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(14).background(Palette.paper, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.accessibilityIdentifier("support.messages")
            if store.conversation != nil {
                Text(L10n.translate("Write a reply")).fontWeight(.medium)
                editor(text: $store.reply, label: L10n.translate("Write a reply"), height: 90)
                    .disabled(store.isBusy || store.replyUncertain).accessibilityIdentifier("support.reply")
                if store.reply.utf16.count > 5000 {
                    Text(L10n.translate("Replies can contain up to 5,000 characters.")).foregroundStyle(.red)
                }
                if store.replyUncertain {
                    Button(L10n.translate("Write a new reply…")) { confirmsNewReply = true }.disabled(store.isBusy)
                }
            }
        }
    }

    private func editor(text: Binding<String>, label: String, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(8)
            .frame(height: height).background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.separator))
            .accessibilityLabel(label)
    }
    private func contextRow(_ title: String, _ value: String) -> some View {
        GridRow { Text(L10n.translate(title)); Text(value).frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func displayDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
