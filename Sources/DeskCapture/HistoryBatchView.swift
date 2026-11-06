import SwiftUI

struct HistoryBatchView: View {
    @ObservedObject var store: CaptureStore
    let scope: [CaptureRecord]
    @ObservedObject private var metadata = MediaMetadataStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var displayLimit = 100
    @State private var selected = Set<UUID>()
    @State private var addTags = ""
    @State private var removeTags = ""
    @State private var collection: UUID?
    @State private var favorite = 0
    @State private var includeProjects = false
    @State private var archives: [HistoryArchiveSummary] = []
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmingRemoval = false
    @State private var task: Task<Void, Never>?
    private var available: [CaptureRecord] {
        let current = Set(store.records.map(\.id)); return scope.filter { current.contains($0.id) }
    }
    private var chosen: [CaptureRecord] { available.filter { selected.contains($0.id) } }
    var body: some View {
        StudioDialog(title: L10n.text("批量整理与恢复"), symbol: "square.stack.3d.up", width: 920, height: 640) {
            VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L10n.text("范围"), value: L10n.text("当前搜索结果 · \(available.count) 项")).foregroundStyle(Palette.muted)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading) {
                    StudioBatchSelectionBar(total: available.count, selected: chosen.count,
                        select: { selected = Set(available.prefix(1000).map(\.id)) }, clear: { selected = [] })
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(available.prefix(displayLimit))) { record in
                                let value = metadata.value(MediaMetadataKey.capture(record.id))
                                Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { enabled in
                                    if enabled && selected.count < 1000 { selected.insert(record.id) } else { selected.remove(record.id) }
                                })) {
                                    HStack {
                                        Text(value.title.isEmpty ? record.title : value.title).lineLimit(1)
                                        Spacer()
                                        Text(record.createdAt.formatted(date: .numeric, time: .shortened)).foregroundStyle(.secondary)
                                    }.font(.system(size: 13))
                                }.toggleStyle(.checkbox)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(selected.contains(record.id) ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .disabled(!selected.contains(record.id) && selected.count >= 1000)
                            }
                        }
                    }.frame(minHeight: 200, maxHeight: .infinity)
                    if displayLimit < available.count { Button(L10n.text("再显示100条")) { displayLimit += 100 } }
                    Toggle(L10n.text("导出时包含可编辑工程（含原图）"), isOn: $includeProjects).toggleStyle(.checkbox)

                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InspectorGroup(L10n.text("批量分类"), initiallyExpanded: true) {
                    InspectorField(title: L10n.text("添加标签")) { TextField(L10n.text("逗号分隔"), text: $addTags) }
                    InspectorField(title: L10n.text("移除标签")) { TextField(L10n.text("逗号分隔"), text: $removeTags) }
                    InspectorField(title: L10n.text("加入集合")) { Picker(L10n.text("加入集合"), selection: $collection) {
                        Text(L10n.text("不改变")).tag(nil as UUID?)
                        ForEach(metadata.snapshot.collections) { Text($0.name).tag(Optional($0.id)) }
                    }
                    }
                    InspectorField(title: L10n.text("收藏")) { Picker(L10n.text("收藏"), selection: $favorite) { Text(L10n.text("不改变")).tag(0); Text(L10n.text("设为收藏")).tag(1); Text(L10n.text("取消收藏")).tag(2) } }

                    Button(L10n.text("应用到选中素材")) { classify() }.disabled(chosen.isEmpty)
                    }
                    InspectorGroup(L10n.text("恢复已移除的批次")) {
                        HStack { Spacer(); Button(L10n.text("刷新批次")) { reloadArchives() }.controlSize(.small) }
                        if archives.isEmpty { Text(L10n.text("暂无可恢复批次")).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(archives) { archive in
                                HStack {
                                    Text(L10n.text("\(archive.count)条 · \(archive.createdAt.formatted(date: .numeric, time: .shortened))")).font(.system(size: 13))
                                    Spacer(); Button(L10n.text("恢复")) {
                                        perform {
                                            try await store.restoreBatch(archive.id)
                                            archives = (try? await background { try HistoryTransactions.archives(store.directory) }) ?? archives
                                            notice = L10n.text("已恢复图片、工程和历史索引；原分类关系保留。")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 300).padding(.leading, 16)
            }.disabled(busy)
            if let error { StudioMessage(text: error, kind: .error) }
            if let notice { StudioMessage(text: notice, dismiss: { self.notice = nil }) }
            if busy { HStack { ProgressView().controlSize(.small); Text(L10n.text("正在处理…")); Button(L10n.text("取消任务")) { task?.cancel() } } }
            }
        } actions: {
            Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(L10n.text("移除选中（可恢复）")) { confirmingRemoval = true }.disabled(chosen.isEmpty || busy)
            Button(L10n.text("导出选中…")) { export() }.disabled(chosen.isEmpty || busy).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task { await metadata.reload(); if !Task.isCancelled { reloadArchives() } }
            .onDisappear { task?.cancel() }
            .alert(L10n.text("移除选中的\(chosen.count)条截图？"), isPresented: $confirmingRemoval) {
                Button(L10n.text("取消"), role: .cancel) { }
                Button(L10n.text("移入可恢复批次"), role: .destructive) {
                    let ids = Set(chosen.map(\.id))
                    perform {
                        let archive = try await store.removeBatch(ids)
                        selected = []; archives = (try? await background { try HistoryTransactions.archives(store.directory) }) ?? archives
                        notice = L10n.text("已移除\(archive.records.count)条；可在本窗口恢复。")
                    }
                }
            } message: { Text(L10n.text("只移除当前选中项。图片、文字索引和工程一起提交或回滚；其他截图和已导出文件保留。")) }
    }
    private func tags(_ text: String) -> [String] { text.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; notice = nil
        task = Task {
            defer { busy = false }
            do { try await work() } catch {
                if Task.isCancelled { notice = L10n.text("任务已取消；已提交的完整批次可在历史或恢复区查看。") }
                else { self.error = error.localizedDescription }
            }
        }
    }
    private func reloadArchives() { perform { archives = try await background { try HistoryTransactions.archives(store.directory) } } }
    private func classify() {
        guard addTags.utf8.prefix(4097).count <= 4096, removeTags.utf8.prefix(4097).count <= 4096 else { error = L10n.text("标签输入每项最多4KB。"); return }
        let keys = Set(chosen.map { MediaMetadataKey.capture($0.id) })
        let expected = Dictionary(uniqueKeysWithValues: keys.map { ($0, metadata.value($0)) })
        let change = MediaBatchClassification(addTags: tags(addTags), removeTags: tags(removeTags), addCollection: collection, favorite: favorite == 0 ? nil : favorite == 1)
        perform { try await metadata.classifyBatch(keys, change: change, expected: expected); notice = L10n.text("已统一更新\(keys.count)条分类。") }
    }
    private func export() {
        let rows = chosen, projects = includeProjects, directory = store.directory
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let output = parent.appendingPathComponent("DeskCapture-批量-\(UUID())")
        perform {
            try await background { try CaptureBatchExporter.export(rows, directory: directory, includeProjects: projects, to: output) }
            notice = L10n.text("完整批次已导出：\(output.path)")
        }
    }
    private func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
