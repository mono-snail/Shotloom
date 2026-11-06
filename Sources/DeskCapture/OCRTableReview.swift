import AppKit
import Darwin

struct OCRTableExports {
    let table: OCRTableResult
    let tsv: String
    let tsvData: Data
    let html: Data
    let json: Data
    let textPreview: String
}
enum OCRTableExport {
    private struct Cell: Encodable {
        let row: Int, column: Int, rowSpan: Int, columnSpan: Int
        let text: String
    }
    private struct Document: Encodable {
        let version = 1
        let indexBase = 0
        let rows: Int, columns: Int
        let cells: [Cell]
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
    static func prepare(_ cells: [OCRTableCell]) throws -> OCRTableExports {
        let table = try OCRTableResult.assemble(cells)
        let width = table.rows.first?.count ?? 0, height = table.rows.count
        var anchors: [Int: OCRTableCell] = [:], covered = Set<Int>()
        for cell in cells {
            try Task.checkCancellation()
            anchors[cell.row * width + cell.column] = cell
            for row in cell.row..<cell.row + cell.rowSpan {
                for column in cell.column..<cell.column + cell.columnSpan { covered.insert(row * width + column) }
            }
        }
        var html = L10n.text("<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><title>表格复核结果</title><table border=\"1\" style=\"border-collapse:collapse\">")
        for row in 0..<height {
            try Task.checkCancellation(); html += "<tr>"
            for column in 0..<width {
                let key = row * width + column
                if let cell = anchors[key] {
                    html += "<td rowspan=\"\(cell.rowSpan)\" colspan=\"\(cell.columnSpan)\">" + escape(cell.text) + "</td>"
                } else if !covered.contains(key) { html += "<td></td>" }
            }
            html += "</tr>"
        }
        html += "</table></html>"
        let document = Document(rows: height, columns: width,
                                cells: cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map {
            Cell(row: $0.row, column: $0.column, rowSpan: $0.rowSpan, columnSpan: $0.columnSpan, text: $0.text)
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(document), htmlData = Data(html.utf8), tsv = table.tsv
        guard htmlData.count <= 32_000_000, json.count <= 32_000_000 else { throw CaptureError.message(L10n.text("表格输出超过32MB，尚未交付。")) }
        try Task.checkCancellation()
        return .init(table: table, tsv: tsv, tsvData: Data(tsv.utf8), html: htmlData, json: json, textPreview: String(tsv.prefix(4000)))
    }
    static func write(_ data: Data, to destination: URL, beforeCommit: (() throws -> Void)? = nil) throws {
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".DeskCapture-table-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        try Task.checkCancellation()
        try data.write(to: stage, options: .withoutOverwriting)
        try beforeCommit?(); try Task.checkCancellation()
        guard Darwin.rename(stage.path, destination.path) == 0 else { throw CaptureError.message(L10n.text("表格保存提交失败，原目标保持。")) }
    }

}

@MainActor
final class OCRTableReviewModel: ObservableObject {
    @Published private(set) var cells: [OCRTableCell]
    @Published private(set) var pendingLines: [OCRLine]
    @Published private(set) var output: OCRTableExports?
    @Published private(set) var busy = false
    @Published private(set) var exporting = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    init(_ table: OCRTableResult) { cells = table.cells; pendingLines = table.unassignedLines; rebuild() }
    func update<T: Equatable>(_ index: Int, _ key: WritableKeyPath<OCRTableCell, T>, _ value: T) {
        guard !exporting, cells.indices.contains(index), cells[index][keyPath: key] != value else { return }
        cells[index][keyPath: key] = value; rebuild()
    }
    func remove(_ index: Int) {
        guard !exporting, cells.indices.contains(index) else { return }
        cells.remove(at: index); rebuild()
    }
    func append() {
        guard !exporting, cells.count < 16_384 else { return }
        cells.append(.init(row: 0, column: 0, rowSpan: 1, columnSpan: 1, text: "")); rebuild()
    }
    func ignoreLine(_ id: UUID) { guard !exporting else { return }; pendingLines.removeAll { $0.id == id } }
    func includeLine(_ id: UUID, atTop: Bool) {
        guard !exporting, let line = pendingLines.first(where: { $0.id == id }), cells.count < 16_384 else { return }
        let width = max(1, cells.map { $0.column + $0.columnSpan }.max() ?? 1)
        let row = atTop ? 0 : (cells.map { $0.row + $0.rowSpan }.max() ?? 0)
        if atTop { for index in cells.indices { cells[index].row += 1 } }
        cells.append(.init(row: row, column: 0, rowSpan: 1, columnSpan: width, text: line.text, bounds: line.bounds))
        pendingLines.removeAll { $0.id == id }; rebuild()
    }
    func cancel() { generation = UUID(); task?.cancel(); exportTask?.cancel(); output = nil; busy = false; exporting = false }
    private func rebuild() {
        generation = UUID(); task?.cancel(); output = nil; busy = true; error = nil; notice = nil
        let snapshot = cells, token = generation
        task = Task { [self] in
            let worker = Task.detached { try OCRTableExport.prepare(snapshot) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, generation == token else { return }
                output = result; busy = false
            } catch { if generation == token { busy = false; self.error = error.localizedDescription } }
        }
    }
    func save(to url: URL) {
        guard !exporting, pendingLines.isEmpty, let output else { return }
        let data: Data
        switch url.pathExtension.lowercased() {
        case "html", "htm": data = output.html
        case "json": data = output.json
        case "tsv", "txt": data = output.tsvData
        default: error = L10n.text("请选择HTML、JSON或TSV扩展名。"); return
        }
        exporting = true; error = nil; notice = nil
        let token = generation
        exportTask = Task { [self] in
            let worker = Task.detached {
                try Task.checkCancellation()
                try OCRTableExport.write(data, to: url)
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard generation == token else { return }
                exporting = false; notice = L10n.text("表格已保存。")
            } catch { if generation == token { exporting = false; self.error = error.localizedDescription } }
        }
    }
}
