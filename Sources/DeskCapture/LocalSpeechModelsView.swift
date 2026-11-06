import SwiftUI
import UniformTypeIdentifiers

struct LocalSpeechModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var installed = Set<LocalSpeechTier>()
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var activeTier: LocalSpeechTier?
    @State private var actionTitle = ""
    @State private var cancelling = false
    @State private var loading = true
    @State private var status: String?
    @State private var statusKind: StudioMessageKind = .information
    var body: some View {
        StudioDialog(title: L10n.text("本地字幕模型"), symbol: "waveform", width: 660, height: 420) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(LocalSpeechTier.allCases) { tier in
                        HStack(spacing: 12) {
                            Image(systemName: "waveform").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.ice)
                                .frame(width: 40, height: 40).background(Palette.selection, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tier.title).font(.system(size: 13, weight: .medium))
                                Text(loading ? L10n.text("正在读取…") : activeTier == tier ? (cancelling ? L10n.text("正在取消…") : actionTitle + L10n.text("中…")) : installed.contains(tier) ? L10n.text("已安装") : L10n.text("未安装"))
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 8)
                            if activeTier == tier { ProgressView().controlSize(.small) }
                            if !installed.contains(tier) { Button(L10n.text("下载")) { begin(tier, title: L10n.text("下载")) { try await LocalSpeechModels.shared.download(tier) } } }
                            StudioMenu(L10n.text("管理")) {
                                Button(L10n.text("导入模型…")) { importModel(tier) }
                                if installed.contains(tier) {
                                    Button(L10n.text("重新下载")) { begin(tier, title: L10n.text("下载")) { try await LocalSpeechModels.shared.download(tier) } }
                                    Button(L10n.text("删除模型"), role: .destructive) { begin(tier, title: L10n.text("删除")) { try await LocalSpeechModels.shared.remove(tier) } }
                                }
                            }.fixedSize()
                        }.padding(12).modifier(StudioPaperSurface())
                            .disabled(operation != nil || loading)
                    }
                    if let status { StudioMessage(text: status, kind: statusKind, dismiss: { self.status = nil }) }
                    if LocalSpeechTranscriber.runtime == nil { StudioMessage(text: L10n.text("本地引擎不可用"), kind: .warning) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Link(L10n.text("模型来源与许可"), destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!)
            Spacer()
            if operation != nil {
                Button(cancelling ? L10n.text("正在取消…") : L10n.text("取消处理")) { cancelling = true; operation?.cancel() }.disabled(cancelling)
            }
            Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .task {
            let current = generation
            let result = await LocalSpeechModels.shared.installed()
            guard !Task.isCancelled, generation == current else { return }
            installed = result; loading = false
        }
        .onDisappear { generation = UUID(); operation?.cancel() }
    }
    private func begin(_ tier: LocalSpeechTier, title: String, work: @escaping @Sendable () async throws -> Void) {
        guard operation == nil, !loading else { return }
        let current = UUID(); generation = current
        activeTier = tier; actionTitle = title; cancelling = false; status = nil
        operation = Task {
            defer {
                if generation == current { operation = nil; activeTier = nil; cancelling = false }
            }
            do {
                try await work()
                guard generation == current else { return }
                status = L10n.text("\(tier.title) · \(title)完成"); statusKind = .information
            } catch {
                guard generation == current else { return }
                status = Task.isCancelled ? L10n.text("\(title)已取消。") : error.localizedDescription
                statusKind = Task.isCancelled ? .information : .error
            }
            guard generation == current else { return }
            let result = await LocalSpeechModels.shared.installed()
            guard generation == current else { return }; installed = result
        }
    }
    private func importModel(_ tier: LocalSpeechTier) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let input = panel.url else { return }
            begin(tier, title: L10n.text("导入")) { try await LocalSpeechModels.shared.importFile(input, tier: tier) }
        }
    }
}
