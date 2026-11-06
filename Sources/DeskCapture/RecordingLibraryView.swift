import AppKit
import SwiftUI

struct RecordingLibraryView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject private var recorder: ScreenRecorder
    @ObservedObject private var metadata = MediaMetadataStore.shared
    @State private var toTrash: RecordingLibraryEntry?
    @State private var entries: [RecordingLibraryEntry] = []
    @State private var busy: URL?
    @State private var recoveryTask: Task<Void, Never>?
    @State private var reloadTask: Task<[RecordingLibraryEntry], Error>?
    @State private var reloadGeneration = UUID()
    @State private var message: String?
    @State private var messageKind: StudioMessageKind = .information
    @State private var loadError: String?
    @State private var loading = true
    @State private var editingMetadata: MediaMetadataSelection?
    @State private var query = ""
    @State private var matchingIDs: Set<URL>?
    @State private var completedSearchKey: MediaQueryKey?
    @State private var searchError: String?
    @State private var searchRetryID: UUID?
    @State private var searchIndex = RecordingSearchIndex()
    @State private var entriesRevision = UUID()
    @State private var searching = false
    @State private var displayLimit = 100
    @State private var lastPageQuery = ""
    @State private var showingBatch = false
    @State private var batchScope: [RecordingLibraryEntry] = []
    @State private var hoveredID: URL?
    init(app: AppCoordinator) { self.app = app; recorder = app.recorder }

    private var searchKey: MediaQueryKey { .init(text: query, revision: entriesRevision, metadataSequence: metadata.snapshot.sequence, retry: searchRetryID) }
    private var searchPending: Bool { !query.isEmpty && (searching || completedSearchKey != searchKey) }
    private var currentSearchError: String? { !query.isEmpty && completedSearchKey == searchKey ? searchError : nil }
    private var visibleEntries: [RecordingLibraryEntry] {
        guard !query.isEmpty else { return entries }
        guard completedSearchKey == searchKey else { return [] }
        return entries.filter { matchingIDs?.contains($0.id) == true }
    }
    private var footer: String {
        if loading { return L10n.text("正在加载录屏素材…") }
        if searchPending { return L10n.text("正在搜索…") }
        if currentSearchError != nil { return L10n.text("搜索未完成") }
        if displayLimit < visibleEntries.count { return L10n.text("已显示 \(displayLimit) / \(visibleEntries.count) 份录屏") }
        return query.isEmpty ? L10n.text("\(visibleEntries.count) 份录屏") : L10n.text("找到 \(visibleEntries.count) 份录屏")
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioLibraryHeader(title: L10n.text("录屏素材"), symbol: "film.stack", count: entries.count) {
                StudioMenu(L10n.text("整理")) {
                    Button(L10n.text("批量整理当前结果…")) { batchScope = visibleEntries; showingBatch = true }
                        .disabled(busy != nil || loading || searchPending || currentSearchError != nil || visibleEntries.isEmpty || recorder.state != .idle)
                    Button(L10n.text("捕获历史…")) { app.showHistory() }
                }.fixedSize()
                StudioIconButton(title: L10n.text("刷新录屏素材"), symbol: "arrow.clockwise") { Task { await reload() } }
                    .disabled(busy != nil || loading)
                Button(L10n.text("打开视频…")) { app.importVideo() }.buttonStyle(StudioButtonStyle(command: true))
            }
            StudioLibrarySearch(title: L10n.text("搜索视频、字幕或标签"), text: $query, searching: searchPending)
                .padding(.horizontal, 20).padding(.bottom, 16)
            if let error = currentSearchError ?? metadata.error ?? loadError {
                StudioMessage(text: error, kind: .warning).padding(.horizontal, 20).padding(.bottom, 12)
            }
            if let message {
                StudioMessage(text: message, kind: messageKind, dismiss: { self.message = nil })
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            content
            if busy != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在处理录屏素材…")).font(.system(size: 12))
                    Spacer()
                    Button(L10n.text("取消处理")) { recoveryTask?.cancel() }.controlSize(.small)
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            StudioLibraryFooter(summary: footer, moreTitle: displayLimit < visibleEntries.count && !searchPending ? L10n.text("再显示100份") : nil) {
                displayLimit += 100
            }
        }
        .frame(minWidth: StudioMetrics.libraryMinimum.width, minHeight: StudioMetrics.libraryMinimum.height)
        .foregroundStyle(Palette.white).background(Palette.ink)
        .sheet(isPresented: $showingBatch, onDismiss: { Task { await reload() } }) { RecordingBatchView(recorder: recorder, scope: batchScope) }
        .sheet(item: $editingMetadata) { MediaMetadataEditor(store: metadata, item: $0) }
        .task { await reload(); if !Task.isCancelled { await metadata.reload() } }
        .task(id: searchKey) { await search() }
        .onDisappear { recoveryTask?.cancel(); reloadTask?.cancel(); reloadGeneration = UUID() }
        .alert(L10n.text("移除这份录屏（可恢复）？"), isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button(L10n.text("取消"), role: .cancel) { toTrash = nil }
            Button(L10n.text("移入恢复区"), role: .destructive) {
                if let entry = toTrash, recorder.state == .idle { remove(entry) }
                toTrash = nil
            }
        } message: { Text(L10n.text("成片、摄像头素材、分段和字幕一起移入恢复区；已导出文件保留。")) }
    }

    @ViewBuilder private var content: some View {
        if loading && entries.isEmpty { StudioLibraryLoading(title: L10n.text("正在加载录屏素材…")) }
        else if searchPending { StudioLibraryLoading(title: L10n.text("正在搜索视频…")) }
        else if currentSearchError != nil {
            StudioLibraryEmpty(title: L10n.text("无法完成这次搜索"), symbol: "magnifyingglass") {
                Button(L10n.text("重试搜索")) { searchRetryID = UUID() }.buttonStyle(StudioButtonStyle(primary: true, command: true))
                Button(L10n.text("清除搜索")) { query = "" }.buttonStyle(StudioButtonStyle(command: true))
            }
        } else if entries.isEmpty && loadError != nil {
            StudioLibraryEmpty(title: L10n.text("录屏素材尚未载入"), symbol: "externaldrive.badge.exclamationmark") {
                Button(L10n.text("重新加载")) { Task { await reload() } }.buttonStyle(StudioButtonStyle(command: true))
            }
        } else if visibleEntries.isEmpty {
            StudioLibraryEmpty(title: query.isEmpty ? L10n.text("还没有录屏素材") : L10n.text("没有匹配的录屏"), symbol: query.isEmpty ? "film.stack" : "magnifyingglass") {
                if query.isEmpty { Button(L10n.text("打开视频…")) { app.importVideo() }.buttonStyle(StudioButtonStyle(command: true)) }
                else { Button(L10n.text("清除搜索")) { query = "" }.buttonStyle(StudioButtonStyle(command: true)) }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(visibleEntries.prefix(displayLimit))) { entry in libraryRow(entry) }
                }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
            }
        }
    }

    private func libraryRow(_ entry: RecordingLibraryEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if let video = entry.video {
                    Button { app.showVideo(video, imported: true) } label: { RecordingLibraryThumbnail(url: video, revision: entriesRevision) }
                        .buttonStyle(StudioMediaButtonStyle()).focusEffectDisabled()
                        .accessibilityLabel(L10n.text("编辑\(title(entry))"))
                        .onDrag { NSItemProvider(contentsOf: video) ?? NSItemProvider() }
                } else { RecordingLibraryThumbnail(url: nil, revision: entriesRevision) }
            }.frame(width: 88, height: 62)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(title(entry)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle).help(title(entry))
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                Text(detail(entry)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).help(detail(entry))
            }.frame(maxWidth: .infinity, alignment: .leading)
            let favorite = metadata.value(MediaMetadataKey.recording(entry.id)).favorite
            StudioIconButton(title: favorite ? L10n.text("取消收藏") : L10n.text("收藏录屏"), symbol: favorite ? "star.fill" : "star", selected: favorite) {
                Task { await metadata.toggleFavorite(MediaMetadataKey.recording(entry.id)) }
            }
            if let video = entry.video { Button(L10n.text("编辑")) { app.showVideo(video, imported: true) }.buttonStyle(StudioButtonStyle(command: true)).controlSize(.small) }
            if entry.video == nil || entry.recoveryAvailable {
                Button(busy == entry.id ? L10n.text("恢复中…") : L10n.text("恢复")) { recover(entry) }
                    .controlSize(.small).disabled(busy != nil || recorder.state != .idle)
            }
            Menu { entryActions(entry) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L10n.text("更多录屏操作")).accessibilityLabel(L10n.text("更多录屏操作"))
        }
        .padding(12).modifier(StudioLibraryItemSurface(hovered: hoveredID == entry.id))
        .onHover { hoveredID = $0 ? entry.id : (hoveredID == entry.id ? nil : hoveredID) }
        .contextMenu { entryActions(entry) }
    }
    @ViewBuilder private func entryActions(_ entry: RecordingLibraryEntry) -> some View {
        if let video = entry.video {
            Button(L10n.text("编辑视频")) { app.showVideo(video, imported: true) }
            Button(L10n.text("用系统播放器打开")) { NSWorkspace.shared.open(video) }
        }
        if entry.video == nil || entry.recoveryAvailable {
            Button(L10n.text("恢复录制分段")) { recover(entry) }.disabled(busy != nil || recorder.state != .idle)
        }
        Divider()
        Button(L10n.text("标签、收藏与集合…")) { editingMetadata = .init(id: MediaMetadataKey.recording(entry.id), title: title(entry)) }
        Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([entry.video ?? entry.id]) }
        Divider()
        Button(L10n.text("移入恢复区…"), role: .destructive) { toTrash = entry }.disabled(busy != nil || recorder.state != .idle)
    }
    private func title(_ entry: RecordingLibraryEntry) -> String {
        let custom = metadata.value(MediaMetadataKey.recording(entry.id)).title
        return custom.isEmpty ? (entry.video?.deletingPathExtension().lastPathComponent ?? L10n.text("待恢复录制")) : custom
    }
    private func detail(_ entry: RecordingLibraryEntry) -> String {
        let tags = metadata.value(MediaMetadataKey.recording(entry.id)).tags.map { "#" + $0 }.joined(separator: " ")
        return [ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file), entry.video == nil ? L10n.text("可恢复分段") : L10n.text("已保存视频"), tags]
            .filter { !$0.isEmpty }.joined(separator: L10n.text(" · "))
    }

    private func reload() async {
        reloadTask?.cancel()
        let generation = UUID(); reloadGeneration = generation
        loading = true; loadError = nil
        let worker = Task.detached(priority: .utility) { try RecordingLibrary.checkedEntries() }
        reloadTask = worker
        do {
            let rows = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            entries = rows; entriesRevision = UUID(); loading = false; reloadTask = nil
        } catch {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            loading = false; reloadTask = nil; loadError = error.localizedDescription
        }
    }
    private func search() async {
        let key = searchKey
        if lastPageQuery != query { displayLimit = 100; lastPageQuery = query }
        searchError = nil
        guard !query.isEmpty else { matchingIDs = nil; completedSearchKey = nil; searching = false; return }
        matchingIDs = []; searching = true
        let rows = entries, snapshot = metadata.snapshot
        do {
            // Avoid repeated subtitle file reads while the query is being typed.
            try await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, key == searchKey else { return }
            let ids = try await searchIndex.search(rows, query: key.text, metadata: snapshot)
            guard !Task.isCancelled, key == searchKey else { return }
            matchingIDs = ids; completedSearchKey = key; searching = false
        } catch {
            guard !Task.isCancelled, key == searchKey else { return }
            searchError = error.localizedDescription; completedSearchKey = key; searching = false
        }
    }
    private func remove(_ entry: RecordingLibraryEntry) {
        guard busy == nil else { return }
        busy = entry.id; message = nil
        recoveryTask = Task {
            defer { busy = nil; recoveryTask = nil }
            let worker = Task.detached { try RecordingBatchTransactions.remove([entry], root: RecordingLibrary.directory) }
            do {
                _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                message = L10n.text("已移入可恢复批次，可在批量整理中恢复。"); messageKind = .information; await reload()
            } catch { message = error.localizedDescription; messageKind = .error }
        }
    }
    private func recover(_ entry: RecordingLibraryEntry) {
        guard busy == nil, recorder.state == .idle else { return }
        busy = entry.id; message = nil
        recoveryTask = Task {
            defer { busy = nil; recoveryTask = nil }
            do {
                let (output, skipped) = try await RecordingLibrary.recover(entry)
                guard !Task.isCancelled else { return }
                message = skipped == 0 ? L10n.text("已恢复视频与可用编辑时间轴；原始分段保留。") : L10n.text("已恢复可用分段，跳过 \(skipped) 个未写好的分段。")
                messageKind = skipped == 0 ? .information : .warning
                await reload()
                guard !Task.isCancelled else { return }; app.showVideo(output, imported: true)
            } catch {
                message = Task.isCancelled ? L10n.text("恢复已取消，原始分段保留。") : error.localizedDescription
                messageKind = Task.isCancelled ? .information : .error
            }
        }
    }
}
