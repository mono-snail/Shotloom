import SwiftUI
import UniformTypeIdentifiers

struct SensitiveBatchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SensitiveBatchModel()
    @StateObject private var rules = SensitiveRuleStore()
    @State private var index = 0
    @State private var preview: CGImage?
    @State private var previewError: String?
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    private var previewKey: String {
        guard model.pages.indices.contains(index) else { return "empty" }
        let page = model.pages[index]
        return page.id.uuidString + page.selected.map(\.uuidString).sorted().joined() + String(describing: page.manualBounds)
    }
    var body: some View {
        StudioWorkspace(title: L10n.text("批量敏感信息复核"), symbol: "lock.shield") {
            Button(L10n.text("选择图片…")) { chooseImages() }.disabled(model.busy)
            Button(L10n.text("检查整个批次")) { model.scan(rules: rules.rules) }.disabled(model.busy || model.pages.isEmpty)
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark") { dismiss() }
        } preview: {
                VStack {
                    if !model.pages.isEmpty {
                        Picker(L10n.text("图片"), selection: $index) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.id) { offset, page in
                                Text(L10n.text("\(offset + 1) / \(model.pages.count)\(page.reviewed ? L10n.text(" · 已复核") : "")")).tag(offset)
                            }
                        }
                    }
                    GeometryReader { geometry in
                        if let preview {
                            let scale = min(geometry.size.width / CGFloat(preview.width), geometry.size.height / CGFloat(preview.height))
                            let size = CGSize(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                            Image(decorative: preview, scale: 1).resizable().frame(width: size.width, height: size.height)
                                .overlay {
                                    if let start, let end {
                                        Rectangle().stroke(.red, lineWidth: 2).frame(width: abs(end.x - start.x), height: abs(end.y - start.y))
                                            .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                                    }
                                }
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                    start = value.startLocation; end = value.location
                                }.onEnded { value in
                                    defer { start = nil; end = nil }
                                    guard !model.busy, model.pages.indices.contains(index), size.width > 0, size.height > 0 else { return }
                                    let a = value.startLocation, b = value.location
                                    let bounds = CGRect(x: min(a.x, b.x) / size.width, y: 1 - max(a.y, b.y) / size.height,
                                                        width: abs(a.x - b.x) / size.width, height: abs(a.y - b.y) / size.height)
                                        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                                    guard !bounds.isEmpty, model.pages[index].manualBounds.count < 256 else { return }
                                    model.pages[index].manualBounds.append(bounds); model.pages[index].reviewed = false
                                })
                                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        } else { Text(L10n.text("选择最多20张图片")).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }

        } inspector: {
            InspectorGroup(L10n.text("识别候选"), initiallyExpanded: true) {
                if model.pages.indices.contains(index) {
                    VStack(alignment: .leading) {
                        Text(L10n.text("第\(index + 1)张：识别候选")).font(.subheadline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.pages[index].candidates) { candidate in
                                    Toggle(isOn: Binding(get: { model.pages.indices.contains(index) && model.pages[index].selected.contains(candidate.id) }, set: { enabled in
                                        if enabled { model.pages[index].selected.insert(candidate.id) } else { model.pages[index].selected.remove(candidate.id) }
                                        model.pages[index].reviewed = false
                                    })) {
                                        VStack(alignment: .leading) {
                                            Text(candidate.line.text).lineLimit(3)
                                            Text(candidate.reason).font(.system(size: 13)).foregroundStyle(.secondary)
                                            if !candidate.line.alternatives.isEmpty { Text(candidate.line.alternatives.joined(separator: " / ")).font(.system(size: 13)) }
                                        }
                                    }.toggleStyle(.checkbox)
                                }
                            }
                        }.frame(minHeight: 120, maxHeight: 300)
                        Button(L10n.text("撤销最近框选（\(model.pages[index].manualBounds.count)）")) {
                            _ = model.pages[index].manualBounds.popLast(); model.pages[index].reviewed = false
                        }.disabled(model.pages[index].manualBounds.isEmpty)
                        Toggle(L10n.text("本张已人工复核"), isOn: $model.pages[index].reviewed).toggleStyle(.checkbox).disabled(!model.pages[index].scanned)
                    }.frame(maxWidth: .infinity, alignment: .leading).disabled(model.busy)
                }
            }
            if let error = rules.loadError ?? model.error ?? previewError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            if model.busy { ProgressView().controlSize(.small); Button(L10n.text("取消任务")) { model.cancel() } }
            if !model.status.isEmpty { Text(model.status).lineLimit(2).textSelection(.enabled) }
            Spacer()
            Button(L10n.text("导出脱敏副本…")) { chooseDestination() }
                .disabled(model.busy || model.pages.isEmpty || !model.pages.allSatisfy { $0.scanned && $0.reviewed })
                .buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task(id: previewKey) {
                preview = nil; previewError = nil
                guard model.pages.indices.contains(index) else { return }
                let page = model.pages[index]
                let worker = Task.detached { try SensitiveBatchIO.flattened(SensitiveBatchIO.read(page.snapshot), bounds: page.redactions) }
                do {
                    let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }; preview = image
                } catch { if !Task.isCancelled { previewError = error.localizedDescription } }
            }
            .onDisappear { model.close() }
    }
    private func chooseImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        index = 0; model.load(panel.urls)
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        model.export(to: parent)
    }
}
