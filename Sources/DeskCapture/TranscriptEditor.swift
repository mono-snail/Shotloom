import SwiftUI

struct TranscriptEditor: View {
    @Binding var captions: [CaptionSegment]
    @Binding var edit: VideoAdvancedEdit
    let duration: Double
    let currentTime: () -> Double
    let seek: (Double) -> Void
    let save: () -> Void
    @State private var query = ""
    @State private var replacement = ""
    @State private var selected: UUID?
    @State private var draftText = ""
    @State private var draftStart = 0.0
    @State private var draftEnd = 0.0
    @State private var speed = 1.0
    @State private var visible: [CaptionSegment] = []
    @State private var total = 0
    @State private var limit = 100
    @State private var revision = UUID()
    @State private var error: String?
    @State private var undo: [Revision] = []
    @State private var replacing: Task<Void, Never>?
    private struct Revision { let captions: [CaptionSegment]; let edit: VideoAdvancedEdit; let cost: Int
        init(captions: [CaptionSegment], edit: VideoAdvancedEdit) { self.captions = captions; self.edit = edit; cost = captions.reduce(0) { $0 + $1.text.utf8.count + 96 } + edit.sections.count * 96 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoControlGrid {
                VideoField(title: L10n.text("查找字幕")) { TextField(L10n.text("查找内容"), text: $query) }
                VideoField(title: L10n.text("当前字幕")) { Button(L10n.text("定位当前句")) { locate() } }
                VideoField(title: L10n.text("替换内容")) { TextField(L10n.text("替换为"), text: $replacement) }
                VideoField(title: L10n.text("批量替换")) { Button(L10n.text("替换匹配文本")) { replace() }.disabled(query.isEmpty || replacement.utf8.count > 64_000) }
            }
            Text(L10n.text("匹配 \(total) 句，显示 \(visible.count) 句")).font(.system(size: 13)).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let time = currentTime()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visible) { caption in
                        HStack(alignment: .top) {
                            Button(caption.keep ? L10n.text("保留") : L10n.text("已删")) { mutate { rows, _ in if let i = rows.firstIndex(where: { $0.id == caption.id }) { rows[i].keep.toggle() } } }
                            Button(String(format: "%.2f", caption.start)) { seek(caption.start); select(caption) }
                            Button { select(caption) } label: { Text(caption.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        }.padding(5).background((time >= caption.start && time < caption.end ? Color.accentColor.opacity(0.16) : selected == caption.id ? Color.secondary.opacity(0.12) : .clear), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            if visible.count < total { Button(L10n.text("再显示100句")) { limit += 100; revision = UUID() } }
            if selected != nil {
                VideoControlGrid {
                    VideoField(title: L10n.text("校对文字")) { TextField(L10n.text("字幕文字"), text: $draftText, axis: .vertical).lineLimit(2...8) }
                    VideoField(title: L10n.text("校对操作")) { Button(L10n.text("应用校对")) { apply() } }
                    VideoField(title: L10n.text("开始时间（秒）")) { TextField(L10n.text("开始秒"), value: $draftStart, format: .number) }
                    VideoField(title: L10n.text("结束时间（秒）")) { TextField(L10n.text("结束秒"), value: $draftEnd, format: .number) }
                    VideoField(title: L10n.text("句子顺序")) {
                        HStack {
                            Button { move(-1) } label: { Image(systemName: "arrow.up") }.help(L10n.text("上移句子"))
                            Button { move(1) } label: { Image(systemName: "arrow.down") }.help(L10n.text("下移句子"))
                        }
                    }
                    VideoField(title: L10n.text("复制字幕")) { Button(L10n.text("复制句子")) { duplicate() } }
                }
            }
            VideoControlGrid {
                VideoField(title: L10n.text("逐句速度")) { Picker(L10n.text("逐句速度"), selection: $speed) { ForEach([0.5, 1, 1.5, 2, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } } }
                VideoField(title: L10n.text("逐句剪辑")) { Button(L10n.text("按句序生成")) { generate() } }
                VideoField(title: L10n.text("撤销修改")) {
                    Button(L10n.text("撤销上一步")) {
                        if let last = undo.popLast() { captions = last.captions; edit = last.edit; selected = nil }
                    }.disabled(undo.isEmpty)
                }
            }
            if let error { Text(error).foregroundStyle(.orange) }
        }
        .disabled(replacing != nil)
        .onDisappear { replacing?.cancel() }
        .task(id: revision) {
            let snapshot = captions, search = query, maximum = limit
            do {
                let worker = Task.detached(priority: .userInitiated) { () throws -> ([CaptionSegment], Int) in
                    let ids = try TranscriptEditing.matching(snapshot, query: search), wanted = Set(ids.prefix(maximum))
                    return (snapshot.filter { wanted.contains($0.id) }, ids.count)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; visible = result.0; total = result.1
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onChange(of: query) { _, _ in limit = 100; revision = UUID() }
        .onChange(of: captions) { _, _ in revision = UUID() }
    }
    private func select(_ row: CaptionSegment) { selected = row.id; draftText = row.text; draftStart = row.start; draftEnd = row.end }
    private func mutate(_ operation: (inout [CaptionSegment], inout VideoAdvancedEdit) throws -> Void) {
        var rows = captions, next = edit
        do {
            try operation(&rows, &next)
            guard rows.count <= 20_000, rows.allSatisfy({ $0.text.utf8.count <= 64_000 }), rows.reduce(0, { $0 + $1.text.utf8.count + 96 }) <= 16_000_000 else { throw CaptureError.message(L10n.text("字幕修改超过预算。")) }
            let previous = Revision(captions: captions, edit: edit)
            if previous.cost <= 16_000_000 { undo.append(previous) }
            while undo.count > 20 || undo.reduce(0, { $0 + $1.cost }) > 16_000_000 { undo.removeFirst() }
            captions = rows; edit = next; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func apply() {
        guard draftStart.isFinite, draftEnd.isFinite, draftStart >= 0, draftEnd > draftStart, draftEnd <= duration else { error = L10n.text("字幕时间必须位于原片内。"); return }
        mutate { rows, _ in if let i = rows.firstIndex(where: { $0.id == selected }) { rows[i].start = draftStart; rows[i].end = draftEnd; rows[i].text = draftText } }
    }
    private func move(_ amount: Int) { mutate { rows, _ in if let i = rows.firstIndex(where: { $0.id == selected }), rows.indices.contains(i + amount) { rows.swapAt(i, i + amount) } } }
    private func duplicate() { mutate { rows, _ in if let i = rows.firstIndex(where: { $0.id == selected }) { var copy = rows[i]; copy.id = UUID(); rows.insert(copy, at: i + 1) } } }
    private func replace() {
        guard replacing == nil else { return }
        let snapshot = captions, currentEdit = edit, search = query, value = replacement
        replacing = Task {
            defer { replacing = nil }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try TranscriptEditing.replacing(snapshot, query: search, replacement: value)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, captions == snapshot, edit == currentEdit else { return }
                mutate { rows, _ in rows = result }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func generate() { mutate { rows, next in next.sections = try TranscriptEditing.sentenceSections(rows, duration: duration, speed: speed) } }
    private func locate() {
        let time = currentTime()
        if let row = captions.first(where: { time >= $0.start && time < $0.end }) {
            query = ""; limit = max(100, (captions.firstIndex(where: { $0.id == row.id }) ?? 0) + 1); select(row); revision = UUID()
        }
    }
}
