import SwiftUI

struct MediaMetadataSelection: Identifiable { let id: String; let title: String }
struct MediaMetadataEditor: View {
    @ObservedObject var store: MediaMetadataStore
    let item: MediaMetadataSelection
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MediaMetadata()
    @State private var expected = MediaMetadata()
    @State private var tags = ""
    @State private var collectionName = ""
    @State private var renamed = ""
    @State private var renaming: UUID?
    @State private var busy = false
    @State private var loading = true
    @State private var loadFailed = false
    @State private var loadRequest = UUID()
    @State private var error: String?
    var body: some View {
        StudioDialog(title: L10n.text("整理素材"), symbol: "tag", width: 580, height: 600) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(item.title).font(.system(size: 13)).foregroundStyle(Palette.muted).lineLimit(2).help(item.title)
                    InspectorField(title: L10n.text("标题")) { TextField(L10n.text("留空沿用原名"), text: $draft.title) }
                    InspectorField(title: L10n.text("标签")) { TextField(L10n.text("逗号分隔"), text: $tags) }
                    Toggle(L10n.text("收藏"), isOn: $draft.favorite)
                    InspectorGroup(L10n.text("所属集合"), initiallyExpanded: true) {
                        if store.snapshot.collections.isEmpty {
                            Text(L10n.text("暂无集合")).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, minHeight: 64)
                        } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(store.snapshot.collections) { collection in
                                    HStack(spacing: 12) {
                                        Toggle(collection.name, isOn: Binding(get: { draft.collections.contains(collection.id) }, set: { enabled in
                                            if enabled { draft.collections.insert(collection.id) } else { draft.collections.remove(collection.id) }
                                        })).toggleStyle(.checkbox).lineLimit(2)
                                        Spacer()
                                        Menu {
                                            Button(L10n.text("重命名…")) { renaming = collection.id; renamed = collection.name }
                                            Button(L10n.text("移除集合"), role: .destructive) {
                                                perform { try await store.removeCollection(collection.id); draft.collections.remove(collection.id); expected.collections.remove(collection.id) }
                                            }
                                        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                                            .menuStyle(.borderlessButton).fixedSize().help(L10n.text("集合操作")).accessibilityLabel(L10n.text("\(collection.name)的操作"))
                                    }
                                }
                            }
                        }.frame(minHeight: 120, maxHeight: 180)
                        }
                        InspectorField(title: L10n.text("新建集合")) {
                            HStack(spacing: 10) {
                                TextField(L10n.text("集合名称"), text: $collectionName).onSubmit { createCollection() }
                                Button(L10n.text("创建")) { createCollection() }.disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        if let id = renaming {
                            InspectorField(title: L10n.text("重命名集合")) {
                                HStack(spacing: 10) {
                                    TextField(L10n.text("新名称"), text: $renamed).onSubmit { renameCollection(id) }
                                    Button(L10n.text("保存名称")) { renameCollection(id) }
                                        .disabled(renamed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button(L10n.text("取消")) { renaming = nil }
                                }
                            }
                        }

                    }
                    if let error { StudioMessage(text: error, kind: .error) }
                }.disabled(loading || loadFailed)
            }
        } actions: {
            Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            if loadFailed {
                Button(L10n.text("重新加载")) { loadRequest = UUID() }.disabled(loading)
            }
            Spacer()
            if busy || loading { ProgressView().controlSize(.small) }
            Button(L10n.text("保存分类")) { saveDraft() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(StudioButtonStyle(primary: true, command: true)).disabled(loading || loadFailed)

        }.disabled(busy)
            .task(id: loadRequest) { await loadDraft() }
    }
    private func loadDraft() async {
        loading = true; error = nil
        await store.reload()
        guard !Task.isCancelled else { return }
        loading = false
        if let issue = store.error { loadFailed = true; error = issue; return }
        loadFailed = false
        expected = store.value(item.id); draft = expected; tags = draft.tags.joined(separator: ", ")
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy, !loading, !loadFailed else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
    private func saveDraft() {
        guard !busy, !loading, !loadFailed else { return }
        guard tags.utf8.prefix(4097).count <= 4096 else { error = L10n.text("标签输入最多4KB。"); return }
        var value = draft
        value.tags = tags.split(whereSeparator: { $0 == "," || $0 == "，" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // A removed collection cannot be resurrected by an old editor.
        value.collections.formIntersection(Set(store.snapshot.collections.map(\.id)))
        perform { try await store.save(key: item.id, value: value, expected: expected); dismiss() }
    }
    private func renameCollection(_ id: UUID) {
        let name = renamed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform { try await store.renameCollection(id, name: name); renaming = nil }
    }
    private func createCollection() {
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform { try await store.addCollection(name); collectionName = "" }
    }
}
