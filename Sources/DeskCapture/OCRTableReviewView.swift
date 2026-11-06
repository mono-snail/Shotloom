import SwiftUI

struct OCRTableReviewView: View {
    let source: CGImage
    let app: AppCoordinator
    let close: () -> Void
    @StateObject private var model: OCRTableReviewModel
    @State private var selected = 0
    @State private var limit = 100
    init(source: CGImage, table: OCRTableResult, app: AppCoordinator, close: @escaping () -> Void) {
        self.source = source; self.app = app; self.close = close
        _model = StateObject(wrappedValue: OCRTableReviewModel(table))
    }
    var body: some View {
        StudioWorkspace(title: L10n.text("表格结构复核"), symbol: "tablecells") {
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark", action: close)
        } preview: {
                VStack {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / CGFloat(source.width), geometry.size.height / CGFloat(source.height))
                        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
                        Image(decorative: source, scale: 1).resizable().frame(width: size.width, height: size.height)
                            .overlay {
                                if model.cells.indices.contains(selected), let bounds = model.cells[selected].bounds {
                                    Rectangle().stroke(.red, lineWidth: 2)
                                        .frame(width: bounds.width * size.width, height: bounds.height * size.height)
                                        .position(x: bounds.midX * size.width, y: (1 - bounds.midY) * size.height)
                                }
                            }.position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }.frame(minWidth: 380, minHeight: 220)
                    if let output = model.output {
                        TextEditor(text: .constant(output.textPreview)).font(.system(size: 11, design: .monospaced)).frame(height: 110)
                    }
                }

        } inspector: {
            InspectorGroup(L10n.text("单元格"), initiallyExpanded: true) {

                    if !model.pendingLines.isEmpty {
                        Text(L10n.text("未归入表格：\(model.pendingLines.count)行，逐项处理后可交付")).font(.system(size: 13)).foregroundStyle(.orange)
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(Array(model.pendingLines.prefix(100))) { line in
                                    HStack {
                                        Text(String(line.text.prefix(160))).lineLimit(2)
                                        Menu(L10n.text("处理")) {
                                            Button(L10n.text("作为顶部合并行")) { model.includeLine(line.id, atTop: true); selected = model.cells.count - 1; limit = max(limit, selected + 1) }
                                            Button(L10n.text("作为底部合并行")) { model.includeLine(line.id, atTop: false); selected = model.cells.count - 1; limit = max(limit, selected + 1) }
                                            Button(L10n.text("忽略这行")) { model.ignoreLine(line.id) }
                                        }
                                    }
                                }
                            }
                        }.frame(maxHeight: 90)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(model.cells.indices.prefix(limit)), id: \.self) { index in
                                let cell = model.cells[index]
                                Button { selected = index } label: {
                                    VStack(alignment: .leading) {
                                        Text(L10n.text("行\(cell.row + 1) 列\(cell.column + 1) · \(cell.rowSpan)×\(cell.columnSpan)")).font(.system(size: 13))
                                        Text(String(cell.text.prefix(160))).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }.buttonStyle(StudioNavigationStyle(selected: selected == index))
                            }
                            if limit < model.cells.count { Button(L10n.text("再显示100格")) { limit += 100 } }
                        }
                    }.frame(height: 150)
                    if model.cells.indices.contains(selected) {
                        HStack {
                            position(L10n.text("行"), key: \.row, span: 4096)
                            position(L10n.text("列"), key: \.column, span: 256)
                        }
                        HStack {
                            span(L10n.text("跨行"), key: \.rowSpan, maximum: 4096)
                            span(L10n.text("跨列"), key: \.columnSpan, maximum: 256)
                        }
                        Text(L10n.text("单元格文字")).fontWeight(.medium)
                        TextEditor(text: Binding(get: { model.cells.indices.contains(selected) ? model.cells[selected].text : "" }, set: { model.update(selected, \.text, $0) }))
                            .font(.system(size: 13)).frame(height: 110)
                        Button(L10n.text("删除本格")) { model.remove(selected); selected = min(selected, max(0, model.cells.count - 1)) }
                    }
                    Button(L10n.text("补充空格")) { model.append(); selected = model.cells.count - 1; limit = max(limit, selected + 1) }

            }.disabled(model.exporting)
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            if let notice = model.notice { Text(notice).foregroundStyle(Palette.muted) }
        } actions: {
            if model.busy || model.exporting { ProgressView().controlSize(.small) }
            Spacer()
            Group {
                StudioMenu(L10n.text("复制表格")) {
                    Button(L10n.text("合并表格")) { if let output = model.output { app.copyReviewedTable(output) } }
                    Button(L10n.text("扁平 TSV")) { if let output = model.output { app.copyText(output.tsv) } }
                }
                Button(L10n.text("保存…")) { save() }.buttonStyle(StudioButtonStyle(primary: true, command: true))
            }.disabled(model.output == nil || model.exporting || !model.pendingLines.isEmpty)
        }
            .onDisappear { model.cancel() }
    }
    private func position(_ title: String, key: WritableKeyPath<OCRTableCell, Int>, span: Int) -> some View {
        Stepper(value: Binding(get: { model.cells.indices.contains(selected) ? model.cells[selected][keyPath: key] + 1 : 1 },
                               set: { model.update(selected, key, $0 - 1) }), in: 1...span) {
            Text("\(title) \(model.cells.indices.contains(selected) ? model.cells[selected][keyPath: key] + 1 : 1)")
        }.font(.system(size: 13))
    }
    private func span(_ title: String, key: WritableKeyPath<OCRTableCell, Int>, maximum: Int) -> some View {
        Stepper(value: Binding(get: { model.cells.indices.contains(selected) ? model.cells[selected][keyPath: key] : 1 },
                               set: { model.update(selected, key, $0) }), in: 1...maximum) {
            Text("\(title) \(model.cells.indices.contains(selected) ? model.cells[selected][keyPath: key] : 1)")
        }.font(.system(size: 13))
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("表格.html")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.save(to: url)
    }
}
