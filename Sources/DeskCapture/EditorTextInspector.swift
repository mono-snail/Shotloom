import AppKit
import SwiftUI

/// A panel can close without throwing away a user's unfinished correction.
@MainActor
final class EditorTextDraft: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var modified = false
    @Published private(set) var initialized = false
    @Published var saving = false
    @Published var feedback: String?
    @Published var feedbackKind: StudioMessageKind = .information
    @Published var replacements: [UUID: String] = [:]
    @Published var rewriteExpanded = false
    @Published var editingText = false
    private(set) var revision: UInt64 = 0

    func seed(_ stored: String?) {
        guard !initialized else { return }
        text = stored ?? ""; initialized = true
    }
    func edit(_ value: String) {
        text = value; modified = true; revision &+= 1; feedback = nil
    }
    func acceptRecognition(_ value: String, expectedRevision: UInt64) {
        guard !modified, revision == expectedRevision else { return }
        text = value
    }
    func saved(revision expected: UInt64) {
        if revision == expected { modified = false; feedback = L10n.text("文字校对已保存。") }
        else { feedback = L10n.text("已保存提交时的校对内容，当前修改尚未保存。") }
        feedbackKind = .information
    }
}

struct EditorTextInspector: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var store: CaptureStore
    @ObservedObject var document: AnnotationDocument
    @ObservedObject var draft: EditorTextDraft
    let record: CaptureRecord
    let close: () -> Void
    @State private var loading = false
    @State private var recognitionError: String?
    private enum Field: Hashable { case text, replacement(UUID) }
    @FocusState private var focusedField: Field?
    private var storedText: String? { store.records.first { $0.id == record.id }?.recognizedText }
    private var reviewCount: Int { document.ocrLines.filter(\.needsReview).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("识别文字")).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if draft.modified { Circle().fill(Palette.ice).frame(width: 5, height: 5).accessibilityLabel(L10n.text("校对尚未保存")) }
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.small) }
                StudioIconButton(title: L10n.text("收起文字面板"), symbol: "sidebar.right", action: close)
            }.padding(.horizontal, StudioMetrics.contentInset).frame(height: 48)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = recognitionError ?? app.recognitionErrors[record.id] {
                        StudioMessage(text: error, kind: .warning)
                        Button(L10n.text("重新识别")) { retry = UUID() }.disabled(loading).controlSize(.small)
                    }
                    TextEditor(text: Binding(get: { draft.text }, set: { draft.edit($0) }))
                        .focused($focusedField, equals: .text)
                        .font(.system(size: 13)).scrollContentBackground(.hidden)
                        .padding(8).frame(height: 200)
                        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.separator))
                        .accessibilityLabel(L10n.text("识别结果与校对文字"))
                    Toggle(L10n.text("显示原图定位框"), isOn: $document.showsOCRLocations)
                        .toggleStyle(InspectorToggleStyle()).disabled(document.ocrLines.isEmpty)
                    if !loading, document.ocrLines.isEmpty, draft.text.isEmpty, recognitionError == nil {
                        Text(L10n.text("没有识别到文字")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    if reviewCount > 0 {
                        Label(L10n.text("\(reviewCount) 行待校对"), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    InspectorGroup(L10n.text("改写原图文字"), expanded: $draft.rewriteExpanded) {
                        ForEach(Array(document.ocrLines.enumerated()), id: \.element.id) { index, line in
                            replacement(line, index: index)
                        }
                    }.disabled(document.ocrLines.isEmpty)
                    if document.replacingOCR {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L10n.text("正在重建文字背景…")).font(.system(size: 12))
                            Spacer(minLength: 0)
                            Button(L10n.text("取消")) { document.cancelOCRReplacement() }.controlSize(.small)
                        }
                    }
                    if let error = document.ocrReplacementError { StudioMessage(text: error, kind: .warning) }
                    Button(L10n.text("标出邮箱与手机号")) {
                        let count = document.suggestSensitiveRedactions()
                        app.flash(count == 0 ? L10n.text("未发现邮箱或手机号。") : L10n.text("已标出 \(count) 行，请检查遮盖范围后再保存。"))
                    }.controlSize(.small).disabled(document.ocrLines.isEmpty)
                    if let feedback = draft.feedback { StudioMessage(text: feedback, kind: draft.feedbackKind, dismiss: { draft.feedback = nil }) }
                }.padding(StudioMetrics.contentInset)
            }
            Divider()
            HStack(spacing: 10) {
                if draft.saving { ProgressView().controlSize(.small) }
                Button(L10n.text("保存校对")) { saveCorrection() }.disabled(draft.saving || !draft.initialized)
                    .keyboardShortcut(focusedField == nil ? nil : KeyboardShortcut("s", modifiers: .command))
                Spacer(minLength: 0)
                Button(L10n.text("复制文字")) { app.copyText(draft.text) }.buttonStyle(StudioButtonStyle(primary: true, command: true)).disabled(draft.text.isEmpty)
            }.controlSize(.small).padding(.horizontal, StudioMetrics.contentInset).frame(height: 56)
                .background(Palette.paper)
        }
        .background(Palette.ink).buttonStyle(StudioButtonStyle(command: true))
        .task(id: retry) { await recognize() }
        .onChange(of: focusedField) { _, field in draft.editingText = field != nil }
        .onDisappear { draft.editingText = false; document.showsOCRLocations = false; document.cancelOCRReplacement() }
    }
    @State private var retry = UUID()

    private func replacement(_ line: OCRLine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(index + 1)").monospacedDigit().foregroundStyle(Palette.muted)
                Text(line.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(line.text)
                if line.needsReview { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel(L10n.text("待校对")) }
            }.font(.system(size: 12))
            TextField(L10n.text("替换内容"), text: Binding(get: { draft.replacements[line.id] ?? line.text }, set: { draft.replacements[line.id] = $0 }))
                .focused($focusedField, equals: .replacement(line.id))
                .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("第\(index + 1)行替换内容"))
            HStack(spacing: 8) {
                OCRFontFittingButton(document: document, line: line, text: draft.replacements[line.id] ?? line.text)
                if !line.alternatives.isEmpty {
                    Menu(L10n.text("候选")) {
                        ForEach(alternatives(line), id: \.self) { candidate in
                            Button(candidate) { draft.replacements[line.id] = candidate }
                        }
                    }.fixedSize()
                }
                Spacer(minLength: 0)
                Button(L10n.text("替换")) { Task { await document.replaceOCRLine(line, with: draft.replacements[line.id] ?? line.text) } }
                    .disabled(document.replacingOCR || (draft.replacements[line.id] ?? line.text).isEmpty)
            }.controlSize(.small)
            Divider()
        }
    }
    private func recognize() async {
        let request = retry
        draft.seed(storedText)
        recognitionError = nil
        let revision = draft.revision
        loading = true
        defer { if retry == request { loading = false } }
        do {
            let source = document.original
            let lines = document.ocrLines.isEmpty ? try await CaptureEngine.recognizeLines(source) : document.ocrLines
            guard !Task.isCancelled, retry == request else { return }
            if document.ocrLines.isEmpty { document.ocrLines = lines }
            document.showsOCRLocations = true
            if let storedText { draft.acceptRecognition(storedText, expectedRevision: revision) }
            else {
                let snapshot = document.ocrLines
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let text = snapshot.map(\.text).joined(separator: "\n")
                    try Task.checkCancellation(); return text
                }
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, retry == request else { return }
                draft.acceptRecognition(storedText ?? text, expectedRevision: revision)
                try await store.setTextAsync(text, for: record.id, onlyIfMissing: true)
            }
        } catch {
            guard !Task.isCancelled, retry == request else { return }; recognitionError = error.localizedDescription
        }
    }
    private func alternatives(_ line: OCRLine) -> [String] {
        var seen = Set<String>()
        return ([line.text] + line.alternatives).filter { seen.insert($0).inserted }
    }
    private func saveCorrection() {
        guard !draft.saving else { return }
        let text = draft.text, revision = draft.revision
        draft.saving = true; draft.feedback = nil
        Task {
            defer { draft.saving = false }
            do { try await store.setTextAsync(text, for: record.id); draft.saved(revision: revision) }
            catch { draft.feedback = error.localizedDescription; draft.feedbackKind = .error }
        }
    }
}
