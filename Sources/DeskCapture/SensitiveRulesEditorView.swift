import SwiftUI

struct SensitiveRulesEditorView: View {
    @ObservedObject var store: SensitiveRuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [SensitiveRule] = []
    @State private var sample = L10n.text("订单号 ABC123")
    @State private var trialFeedback: String?
    @State private var trialKind: StudioMessageKind = .information
    @State private var saveError: String?
    @State private var saving = false
    @State private var initialized = false
    @State private var testing = false
    @State private var trialGeneration = UUID()
    @State private var trialTask: Task<Void, Never>?

    var body: some View {
        StudioDialog(title: L10n.text("本地敏感信息规则"), symbol: "lock.shield", width: 620, height: 660) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if draft.isEmpty {
                        Label(L10n.text("暂无自定义规则"), systemImage: "text.badge.checkmark")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, minHeight: 72)
                    }
                    ForEach($draft) { $rule in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .bottom, spacing: 12) {
                                InspectorField(title: L10n.text("规则名称")) { TextField(L10n.text("名称"), text: $rule.title) }
                                StudioIconButton(title: L10n.text("删除规则"), symbol: "trash") { draft.removeAll { $0.id == rule.id } }
                            }
                            Toggle(L10n.text("启用规则"), isOn: $rule.enabled)
                            HStack(alignment: .top, spacing: 12) {
                                InspectorField(title: L10n.text("匹配方式")) {
                                    Picker(L10n.text("匹配方式"), selection: $rule.mode) { ForEach(SensitiveRuleMode.allCases) { Text($0.title).tag($0) } }
                                }
                                InspectorField(title: L10n.text("适用范围")) {
                                    Picker(L10n.text("适用范围"), selection: $rule.scope) { ForEach(SensitiveRuleScope.allCases) { Text($0.title).tag($0) } }
                                }
                            }
                            InspectorField(title: L10n.text("匹配内容")) { TextField(L10n.text("文字或受限正则"), text: $rule.pattern) }
                            Toggle(L10n.text("区分大小写"), isOn: $rule.caseSensitive)
                        }.padding(16).modifier(StudioPaperSurface())
                    }
                    Button { draft.append(SensitiveRule()) } label: { Label(L10n.text("添加规则"), systemImage: "plus") }
                        .disabled(draft.count >= 32).controlSize(.small)
                    InspectorGroup(L10n.text("试验规则")) {
                        InspectorField(title: L10n.text("试验文字（图片范围）")) { TextField(L10n.text("输入一行文字"), text: $sample).onSubmit { runTrial() } }
                        HStack(spacing: 10) {
                            Button(L10n.text("检查匹配")) { runTrial() }.disabled(testing || sample.isEmpty).controlSize(.small)
                            if testing { ProgressView().controlSize(.small) }
                        }
                        if let trialFeedback { StudioMessage(text: trialFeedback, kind: trialKind) }
                    }
                    if let saveError { StudioMessage(text: saveError, kind: .error) }
                }
            }
        } actions: {
            Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            Button(L10n.text("保存规则")) { save() }.buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
        .disabled(saving)
        .onAppear {
            guard !initialized else { return }
            initialized = true; draft = store.rules; saveError = store.loadError
        }
        .onChange(of: draft) { _, _ in invalidateTrial() }
        .onChange(of: sample) { _, _ in invalidateTrial() }
        .onDisappear { invalidateTrial() }
    }
    private func invalidateTrial() {
        trialGeneration = UUID(); trialTask?.cancel(); trialTask = nil
        testing = false; trialFeedback = nil
    }
    private func runTrial() {
        guard !testing, !saving, !sample.isEmpty else { return }
        guard sample.utf8.prefix(16_385).count <= 16_384 else {
            trialFeedback = L10n.text("试验文字最多16KB。"); trialKind = .warning; return
        }
        trialTask?.cancel()
        let rules = draft, text = sample, generation = UUID()
        trialGeneration = generation; testing = true; trialFeedback = nil
        trialTask = Task {
            defer { if trialGeneration == generation { testing = false; trialTask = nil } }
            let worker = Task.detached(priority: .userInitiated) {
                let line = OCRLine(text: text, bounds: .init(x: 0, y: 0, width: 1, height: 1), confidence: 1)
                let result = try SensitiveRuleEvaluation.classify([line], kinds: [], rules: rules, scope: .images)
                return result.first.map { L10n.text("命中：") + $0.reason } ?? L10n.text("没有命中自定义规则。")
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, trialGeneration == generation, draft == rules, sample == text else { return }
                trialFeedback = result; trialKind = .information
            } catch {
                guard !Task.isCancelled, trialGeneration == generation else { return }
                trialFeedback = error.localizedDescription; trialKind = .error
            }
        }
    }
    private func save() {
        guard !saving else { return }
        invalidateTrial()
        let snapshot = draft
        saving = true; saveError = nil
        Task {
            defer { saving = false }
            do { try await store.save(snapshot); dismiss() }
            catch { saveError = error.localizedDescription }
        }
    }
}
