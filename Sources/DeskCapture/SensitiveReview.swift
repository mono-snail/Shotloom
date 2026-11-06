import SwiftUI

struct SensitiveReviewView: View {
    @ObservedObject var document: AnnotationDocument
    let done: () -> Void
    @StateObject private var rules = SensitiveRuleStore()
    @State private var kinds = Set(SensitiveKind.allCases)
    @State private var selected = Set<UUID>()
    @State private var candidates: [SensitiveReviewCandidate] = []
    @State private var loading = true
    @State private var error: String?
    @State private var measuredRevision: Int?
    @State private var refresh = UUID()
    @State private var showingRules = false
    private var requestKey: String {
        rules.revision.uuidString + refresh.uuidString + kinds.map(\.rawValue).sorted().joined(separator: ",")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("检查敏感信息")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.text("自定义规则")) { showingRules = true }
                Button(L10n.text("关闭"), action: done)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(SensitiveKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(get: { kinds.contains(kind) }, set: { enabled in
                        if enabled { kinds.insert(kind) } else { kinds.remove(kind) }
                    })).toggleStyle(.checkbox)
                }
            }.font(.system(size: 13))
            Divider()
            if let loadError = rules.loadError { Text(loadError).foregroundStyle(.orange) }
            if loading { ProgressView(L10n.text("正在本地识别与检查…")) }
            if let error { Text(error).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { candidate in
                        Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { enabled in
                            if enabled { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.line.text).lineLimit(2)
                                Text(candidate.reason).foregroundStyle(.secondary).font(.system(size: 12))
                                if !candidate.line.alternatives.isEmpty {
                                    Text(L10n.text("候选：") + candidate.line.alternatives.joined(separator: " / "))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }.toggleStyle(.checkbox)
                    }
                }
            }.frame(maxHeight: 220)
            if !loading && error == nil && candidates.isEmpty { Text(L10n.text("没有找到符合所选规则的文字。")).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.text("重新检查")) { refresh = UUID() }
                Button(L10n.text("全选")) { selected.formUnion(candidates.map(\.id)) }
                Spacer()
                Button(L10n.text("遮盖 \(selected.count) 行")) {
                    guard measuredRevision == document.renderRevision else {
                        error = L10n.text("画面已改变，请重新检查后遮盖。"); return
                    }
                    document.redactOCRLines(candidates.filter { selected.contains($0.id) }.map(\.line)); done()
                }.disabled(loading || selected.isEmpty).buttonStyle(StudioButtonStyle(primary: true, command: true))
            }
        }.padding(20).frame(width: 480).font(.system(size: 13))
            .sheet(isPresented: $showingRules) { SensitiveRulesEditorView(store: rules) }
            .task(id: requestKey) { await scan() }
    }
    @MainActor private func scan() async {
        loading = true; error = nil; candidates = []; selected = []; measuredRevision = nil
        document.commitPendingText?()
        let source = document.original, marks = document.marks, revision = document.renderRevision
        let selectedKinds = kinds, customRules = rules.rules
        let worker = Task.detached(priority: .userInitiated) { () throws -> [SensitiveReviewCandidate] in
            try Task.checkCancellation()
            let snapshot = AnnotationDocument(image: source)
            snapshot.marks = marks
            guard let image = snapshot.render() else { throw CaptureError.message(L10n.text("当前画面无法渲染。")) }
            let lines = try await CaptureEngine.recognizeLines(image)
            try Task.checkCancellation()
            return try SensitiveRuleEvaluation.classify(lines, kinds: selectedKinds, rules: customRules, scope: .images)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled else { return }
            guard revision == document.renderRevision else {
                loading = false; error = L10n.text("检查期间画面已改变，请重新检查。"); return
            }
            candidates = result; selected = Set(result.map(\.id)); measuredRevision = revision; loading = false
        } catch {
            guard !Task.isCancelled else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
}
