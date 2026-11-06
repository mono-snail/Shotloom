import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var store: CaptureStore
    @ObservedObject private var metadata = MediaMetadataStore.shared
    @State private var editingMetadata: MediaMetadataSelection?
    @State private var matchedRecords: [CaptureRecord] = []
    @State private var completedSearchKey: MediaQueryKey?
    @State private var searchError: String?
    @State private var searchRetryID: UUID?
    @State private var searching = false
    @State private var searchIndex = CaptureSearchIndex()
    @State private var pageSize = 100
    @State private var lastPageQuery = ""
    @State private var query = ""
    @State private var gallery = true
    @State private var deleting: CaptureRecord?
    @State private var hoveredID: UUID?
    @State private var confirmingClear = false
    @State private var clearError: String?
    @State private var showingSensitiveBatch = false
    @State private var batchScope: [CaptureRecord] = []
    @State private var showingHistoryBatch = false

    init(app: AppCoordinator, store: CaptureStore, initialGallery: Bool = true) {
        self.app = app; self.store = store
        _gallery = State(initialValue: initialGallery)
    }

    private var searchKey: MediaQueryKey {
        .init(text: query, revision: store.contentRevision, metadataSequence: metadata.snapshot.sequence, retry: searchRetryID)
    }
    private var searchPending: Bool { !query.isEmpty && (searching || completedSearchKey != searchKey) }
    private var currentSearchError: String? { !query.isEmpty && completedSearchKey == searchKey ? searchError : nil }
    private var records: [CaptureRecord] {
        query.isEmpty ? store.records : (completedSearchKey == searchKey ? matchedRecords : [])
    }
    private var issue: String? { currentSearchError ?? metadata.error ?? store.transactionError ?? store.transactionWarning }
    private var footer: String {
        if store.isLoading { return L10n.text("正在加载历史…") }
        if searchPending { return L10n.text("正在搜索…") }
        if currentSearchError != nil { return L10n.text("搜索未完成") }
        if records.count > pageSize { return L10n.text("已显示 \(pageSize) / \(records.count) 张截图") }
        return query.isEmpty ? L10n.text("\(records.count) 张截图") : L10n.text("找到 \(records.count) 张截图")
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioLibraryHeader(title: L10n.text("捕获历史"), symbol: "square.stack.3d.up", count: store.records.count) {
                Button { app.showBeautifier() } label: { Label(L10n.text("图片美化"), systemImage: "sparkles") }
                    .buttonStyle(StudioButtonStyle(command: true))
                Picker(L10n.text("显示方式"), selection: $gallery) {
                    Image(systemName: "square.grid.2x2").accessibilityLabel(L10n.text("画廊")).tag(true)
                    Image(systemName: "list.bullet").accessibilityLabel(L10n.text("列表")).tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 76).help(L10n.text("切换画廊或列表"))
                StudioMenu(L10n.text("整理")) {
                    Button(L10n.text("批量整理当前结果…")) { batchScope = records; showingHistoryBatch = true }
                        .disabled(searchPending || currentSearchError != nil || records.isEmpty)
                    Button(L10n.text("选择图片批量脱敏…")) { showingSensitiveBatch = true }
                    Button(L10n.text("流程…")) { app.showWorkflow() }
                    Divider()
                    Button(L10n.text("录屏素材…")) { app.showRecordings() }
                    Divider()
                    Button(L10n.text("清空全部历史…"), role: .destructive) { confirmingClear = true }.disabled(store.records.isEmpty || store.isLoading)
                }.fixedSize()
                StudioMenu(L10n.text("导入")) {
                    Button(L10n.text("图片…")) { app.importImage() }
                    Button(L10n.text("编辑剪贴板")) { app.editClipboard() }
                    Button(L10n.text("工程…")) { app.importProject() }
                    Button(L10n.text("视频…")) { app.importVideo() }
                }.fixedSize()
            }
            StudioLibrarySearch(title: L10n.text("搜索截图、文字或标签"), text: $query, searching: searchPending)
                .padding(.horizontal, 20).padding(.bottom, 16)
            if let issue { StudioMessage(text: issue, kind: .warning).padding(.horizontal, 20).padding(.bottom, 12) }
            content
            StudioLibraryFooter(summary: footer, moreTitle: pageSize < records.count && !searchPending ? L10n.text("再显示100张") : nil) {
                pageSize += 100
            }
        }
        .frame(minWidth: StudioMetrics.libraryMinimum.width, minHeight: StudioMetrics.libraryMinimum.height)
        .foregroundStyle(Palette.white).background(Palette.ink)
        .sheet(isPresented: $showingSensitiveBatch) { SensitiveBatchView() }
        .sheet(isPresented: $showingHistoryBatch) { HistoryBatchView(store: store, scope: batchScope) }
        .sheet(item: $editingMetadata) { MediaMetadataEditor(store: metadata, item: $0) }
        .task { await metadata.reload() }
        .task(id: searchKey) { await search() }
        .alert(L10n.text("删除这张截图？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.text("取消"), role: .cancel) { deleting = nil }
            Button(L10n.text("删除"), role: .destructive) { if let deleting { app.delete(deleting) }; deleting = nil }
        } message: { Text(L10n.text("图片、文字索引和工程移入可恢复批次；可在批量整理中恢复。已导出文件保留。")) }
        .alert(L10n.text("清空全部 \(store.records.count) 条截图历史？"), isPresented: $confirmingClear) {
            Button(L10n.text("取消"), role: .cancel) { }
            Button(L10n.text("清空全部"), role: .destructive) {
                Task {
                    do { try await app.clearHistory(); query = ""; hoveredID = nil }
                    catch { clearError = error.localizedDescription }
                }
            }
        } message: { Text(L10n.text("将删除所有历史截图、文字索引和可编辑工程，包括搜索未显示的记录。此操作无法撤销；已导出的文件和录屏素材会保留。")) }
        .alert(L10n.text("清空历史未完成"), isPresented: Binding(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
            Button(L10n.text("好")) { clearError = nil }
        } message: { Text(clearError ?? "") }
    }

    @ViewBuilder private var content: some View {
        if store.isLoading && store.records.isEmpty {
            StudioLibraryLoading(title: L10n.text("正在加载历史…"))
        } else if searchPending {
            StudioLibraryLoading(title: L10n.text("正在搜索截图…"))
        } else if currentSearchError != nil {
            StudioLibraryEmpty(title: L10n.text("无法完成这次搜索"), symbol: "magnifyingglass") {
                Button(L10n.text("重试搜索")) { searchRetryID = UUID() }.buttonStyle(StudioButtonStyle(primary: true, command: true))
                Button(L10n.text("清除搜索")) { query = "" }.buttonStyle(StudioButtonStyle(command: true))
            }
        } else if records.isEmpty && store.transactionError != nil {
            StudioLibraryEmpty(title: L10n.text("历史尚未载入"), symbol: "externaldrive.badge.exclamationmark") {
                Button(L10n.text("重新加载")) { Task { try? await store.recoverHistory() } }.buttonStyle(StudioButtonStyle(command: true))
            }
        } else if records.isEmpty {
            StudioLibraryEmpty(title: query.isEmpty ? L10n.text("还没有截图") : L10n.text("没有匹配的截图"), symbol: query.isEmpty ? "viewfinder" : "magnifyingglass") {
                if query.isEmpty {
                    Button(L10n.text("区域截图")) { app.start(.region) }.buttonStyle(StudioButtonStyle(primary: true, command: true)).disabled(app.captureIsBusy)
                    Button(L10n.text("导入图片…")) { app.importImage() }.buttonStyle(StudioButtonStyle(command: true))
                } else { Button(L10n.text("清除搜索")) { query = "" }.buttonStyle(StudioButtonStyle(command: true)) }
            }
        } else {
            ScrollView {
                if gallery {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 224), spacing: 16)], spacing: 16) {
                        ForEach(Array(records.prefix(pageSize))) { galleryCard($0) }
                    }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(records.prefix(pageSize))) { listRow($0) }
                    }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
                }
            }
        }
    }

    private func listRow(_ record: CaptureRecord) -> some View {
        HStack(spacing: 12) {
            thumbnail(record).frame(width: 80, height: 60).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text(mediaTitle(record)).font(.system(size: 13, weight: .medium)).lineLimit(1).help(mediaTitle(record))
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                Text(tags(record).isEmpty ? "\(record.width) × \(record.height) px" : tags(record))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            favoriteButton(record)
            StudioIconButton(title: L10n.text("美化截图"), symbol: "sparkles") { app.beautify(record) }
            Button(L10n.text("复制")) { app.copy(record) }.buttonStyle(StudioButtonStyle(command: true)).controlSize(.small)
            moreMenu(record)
        }
        .padding(12).modifier(StudioLibraryItemSurface(hovered: hoveredID == record.id))
        .onHover { updateHover(record.id, hovered: $0) }
        .contextMenu { recordActions(record) }
    }

    private func galleryCard(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail(record).padding(12).frame(maxWidth: .infinity).frame(height: 140)
                .background(Palette.canvas).clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(mediaTitle(record)).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(mediaTitle(record))
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                if !tags(record).isEmpty {
                    Text(tags(record)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        dimensions(record).fixedSize()
                        Spacer(minLength: 8)
                        galleryActions(record).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        dimensions(record)
                        HStack { Spacer(minLength: 0); galleryActions(record) }
                    }
                }
            }.padding(12)
        }
        .modifier(StudioLibraryItemSurface(hovered: hoveredID == record.id))
        .onHover { updateHover(record.id, hovered: $0) }
        .contextMenu { recordActions(record) }
    }

    private func thumbnail(_ record: CaptureRecord) -> some View {
        Button { app.openEditor(record) } label: { HistoryThumbnailView(url: store.url(for: record)) }
            .buttonStyle(StudioMediaButtonStyle()).focusEffectDisabled()
            .help(L10n.text("编辑截图")).accessibilityLabel(L10n.text("编辑\(mediaTitle(record))"))
            .onDrag { NSItemProvider(contentsOf: store.url(for: record)) ?? NSItemProvider() }
    }
    private func dimensions(_ record: CaptureRecord) -> some View {
        Text("\(record.width) × \(record.height)").font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(Palette.muted).lineLimit(1).help(L10n.text("\(record.width) × \(record.height) 像素"))
    }
    private func galleryActions(_ record: CaptureRecord) -> some View {
        HStack(spacing: 6) {
            favoriteButton(record)
            StudioIconButton(title: L10n.text("美化截图"), symbol: "sparkles") { app.beautify(record) }
            StudioIconButton(title: L10n.text("复制截图"), symbol: "doc.on.doc") { app.copy(record) }
            moreMenu(record)
        }
    }
    private func favoriteButton(_ record: CaptureRecord) -> some View {
        let favorite = metadata.value(MediaMetadataKey.capture(record.id)).favorite
        return StudioIconButton(title: favorite ? L10n.text("取消收藏") : L10n.text("收藏截图"), symbol: favorite ? "star.fill" : "star", selected: favorite) {
            Task { await metadata.toggleFavorite(MediaMetadataKey.capture(record.id)) }
        }
    }
    private func moreMenu(_ record: CaptureRecord) -> some View {
        Menu { recordActions(record) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L10n.text("更多截图操作")).accessibilityLabel(L10n.text("更多截图操作"))
    }
    @ViewBuilder private func recordActions(_ record: CaptureRecord) -> some View {
        Button(L10n.text("编辑截图")) { app.openEditor(record) }
        Button(L10n.text("复制截图")) { app.copy(record) }
        Button(L10n.text("保存文件…")) { app.save(record) }
        Divider()
        Button(L10n.text("图片美化…")) { app.beautify(record) }
        Button(L10n.text("旋转、缩放与拼图…")) { app.transform(record) }
        Button(L10n.text("裁剪与清理…")) { app.cleanup(record) }
        Button(L10n.text("复制文字")) { app.recognize(record, copyAfter: true) }
        Button(L10n.text("运行流程…")) { app.workflow(record) }
        Divider()
        Button(L10n.text("标签、收藏与集合…")) { editMetadata(record) }
        Button(L10n.text("系统分享…")) { app.share(record) }
        Button(L10n.text("导出可编辑工程…")) { app.exportProject(record) }
        Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([store.url(for: record)]) }
        Divider()
        Button(L10n.text("删除…"), role: .destructive) { deleting = record }
    }
    private func tags(_ record: CaptureRecord) -> String { metadata.value(MediaMetadataKey.capture(record.id)).tags.map { "#" + $0 }.joined(separator: " ") }
    private func mediaTitle(_ record: CaptureRecord) -> String {
        let value = metadata.value(MediaMetadataKey.capture(record.id)).title
        return value.isEmpty ? record.title : value
    }
    private func editMetadata(_ record: CaptureRecord) { editingMetadata = .init(id: MediaMetadataKey.capture(record.id), title: mediaTitle(record)) }
    private func updateHover(_ id: UUID, hovered: Bool) { hoveredID = hovered ? id : (hoveredID == id ? nil : hoveredID) }

    private func search() async {
        let key = searchKey
        searchError = nil
        if lastPageQuery != query { pageSize = 100; lastPageQuery = query }
        guard !query.isEmpty else { matchedRecords = []; completedSearchKey = nil; searching = false; return }
        matchedRecords = []; searching = true
        let rows = store.records, snapshot = metadata.snapshot
        do {
            // Coalesce typing before asking the background index to do work.
            try await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, key == searchKey else { return }
            let matches = try await searchIndex.matchingRecords(rows, query: key.text, metadata: snapshot, version: key.revision)
            guard !Task.isCancelled, key == searchKey else { return }
            matchedRecords = matches; completedSearchKey = key; searching = false
        } catch {
            guard !Task.isCancelled, key == searchKey else { return }
            searchError = error.localizedDescription; completedSearchKey = key; searching = false
        }
    }
}
