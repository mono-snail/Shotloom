import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class UISimplificationModel: ObservableObject {
    @Published private(set) var source: CGImage
    @Published private(set) var blocks: [SimplifiedBlock] = []
    @Published private(set) var result: CGImage?
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    private var history: [[SimplifiedBlock]] = []
    private var token = UUID()
    private var task: Task<Void, Never>?
    init(source: CGImage) { self.source = source }
    var canUndo: Bool { !history.isEmpty }
    func cancel() { token = UUID(); task?.cancel(); task = nil; busy = false }
    func detect() {
        cancel(); busy = true; error = nil
        let generation = token, image = source
        task = Task {
            do {
                let inferred = try await UISimplification.detect(image)
                guard !Task.isCancelled, token == generation else { return }
                checkpoint(); blocks = inferred; render()
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
    private func checkpoint() { history.append(blocks); if history.count > 40 { history.removeFirst() } }
    func change(_ id: UUID, _ edit: (inout SimplifiedBlock) -> Void) {
        do {
            let draft = try UISimplification.editing(blocks, id: id, change: edit)
            checkpoint(); blocks = draft; render()
        }
        catch { self.error = error.localizedDescription }
    }
    func add() {
        guard blocks.count < 1024 else { return }
        checkpoint(); blocks.append(.init(kind: .text, bounds: .init(x: 0.1, y: 0.45, width: 0.3, height: 0.05))); render()
    }
    func remove(_ id: UUID) {
        checkpoint(); blocks.removeAll { $0.id == id }
        for index in blocks.indices where blocks[index].parent == id { blocks[index].parent = nil }
        render()
    }
    func undo() { guard let previous = history.popLast() else { return }; blocks = previous; render() }
    func render() {
        cancel(); busy = true; error = nil; result = nil
        let image = source, snapshot = blocks, generation = token
        task = Task {
            let worker = Task.detached { try UISimplification.render(source: image, blocks: snapshot) }
            do {
                let rendered = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, token == generation else { return }; result = rendered; busy = false
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
    func saveProject(to url: URL) {
        cancel(); busy = true; error = nil
        let image = source, snapshot = blocks, generation = token
        task = Task {
            let worker = Task.detached {
                let data = try UISimplification.project(source: image, blocks: snapshot)
                try Task.checkCancellation(); try data.write(to: url, options: .atomic)
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard token == generation else { return }; busy = false; notice = L10n.text("工程已保存，包含可恢复原图；分享图片请使用“保存简化图”。")
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
    func loadProject(from url: URL) {
        cancel(); busy = true; error = nil
        let generation = token
        task = Task {
            let worker = Task.detached {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 90_000_000 else { throw CaptureError.message(L10n.text("工程超过90MB。")) }
                try Task.checkCancellation(); return try UISimplification.open(Data(contentsOf: url))
            }
            do {
                let (image, blocks) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, token == generation else { return }
                source = image; self.blocks = blocks; history = []; render()
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
}

struct UISimplificationView: View {
    @StateObject private var model: UISimplificationModel
    let save: (CGImage) -> Void
    let close: () -> Void
    @State private var selected: UUID?
    @State private var showOriginal = false
    @State private var dragOrigin: CGRect?
    init(image: CGImage, save: @escaping (CGImage) -> Void, close: @escaping () -> Void) {
        _model = StateObject(wrappedValue: UISimplificationModel(source: image)); self.save = save; self.close = close
    }
    var body: some View {
        StudioWorkspace(title: L10n.text("界面简化"), symbol: "square.dashed") {
            Toggle(L10n.text("对照原图"), isOn: $showOriginal)
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark", action: close)
        } preview: {
                GeometryReader { geometry in
                    let image = showOriginal ? model.source : (model.result ?? model.source)
                    let factor = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
                    let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                        if !showOriginal {
                            ForEach(model.blocks) { block in
                                let box = block.bounds
                                Rectangle().stroke(selected == block.id ? Palette.ice : .clear, lineWidth: 2)
                                    .background(Color.clear.contentShape(Rectangle()))
                                    .frame(width: box.width * size.width, height: box.height * size.height)
                                    .offset(x: box.minX * size.width, y: (1 - box.maxY) * size.height)
                                    .onTapGesture { selected = block.id }
                                    .gesture(DragGesture(minimumDistance: 3).onChanged { _ in
                                        selected = block.id; if dragOrigin == nil { dragOrigin = block.bounds }
                                    }.onEnded { value in
                                        defer { dragOrigin = nil }
                                        guard let origin = dragOrigin else { return }
                                        model.change(block.id) {
                                            $0.bounds.origin.x = min(1 - origin.width, max(0, origin.minX + value.translation.width / size.width))
                                            $0.bounds.origin.y = min(1 - origin.height, max(0, origin.minY - value.translation.height / size.height))
                                        }
                                    })
                            }
                        }
                    }.frame(width: size.width, height: size.height)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
        } inspector: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.text("占位对象 \(model.blocks.count)")).font(.subheadline)
                        Spacer(); Button(L10n.text("添加")) { model.add(); selected = model.blocks.last?.id }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                                Button {
                                    selected = block.id
                                } label: {
                                    HStack {
                                        Text(block.kind == .text ? L10n.text("文字 \(index + 1)") : L10n.text("控件 \(index + 1)"))
                                        if block.parent != nil { Image(systemName: "arrow.turn.down.right").help(L10n.text("位于一个候选控件内")) }
                                        Spacer()
                                        if block.restored { Text(L10n.text("原内容")).foregroundStyle(.secondary) }
                                    }.padding(.horizontal, 10).frame(minHeight: 32)
                                        .background(selected == block.id ? Palette.ice.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 150)
                    if let id = selected, let block = model.blocks.first(where: { $0.id == id }) {
                        InspectorField(title: L10n.text("所属控件")) { Picker(L10n.text("所属控件"), selection: Binding<UUID?>(get: { block.parent }, set: { value in model.change(id) { $0.parent = value } })) {
                            Text(L10n.text("顶层")).tag(nil as UUID?)
                            ForEach(Array(model.blocks.enumerated()).filter { $0.element.kind == .control && $0.element.id != id }, id: \.element.id) { index, parent in
                                Text(L10n.text("控件 \(index + 1)")).tag(Optional(parent.id))
                            }
                        }.labelsHidden() }
                        InspectorField(title: L10n.text("显示文字")) { TextField(L10n.text("文字"), text: Binding(get: { block.label }, set: { value in model.change(id) { $0.label = value } })) }
                        Toggle(L10n.text("深色样式"), isOn: Binding(get: { block.darkStyle }, set: { value in model.change(id) { $0.darkStyle = value } }))
                        Toggle(L10n.text("显示原内容"), isOn: Binding(get: { block.restored }, set: { value in model.change(id) {
                            $0.restored = value; if value { $0.bounds = $0.sourceBounds ?? $0.bounds }
                        } }))
                        dimension(L10n.text("左边"), id: id, key: \.origin.x, value: block.bounds.minX)
                        dimension(L10n.text("底边"), id: id, key: \.origin.y, value: block.bounds.minY)
                        dimension(L10n.text("宽度"), id: id, key: \.size.width, value: block.bounds.width)
                        dimension(L10n.text("高度"), id: id, key: \.size.height, value: block.bounds.height)
                        Button(L10n.text("删除对象")) { model.remove(id); selected = nil }
                    }
                }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let notice = model.notice { Text(notice).foregroundStyle(Palette.muted) }
        } actions: {
            StudioIconButton(title: L10n.text("撤销"), symbol: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
            Button(L10n.text("重新识别")) { selected = nil; model.detect() }.disabled(model.busy)
            if model.busy { ProgressView().controlSize(.small); Button(L10n.text("取消")) { model.cancel() } }
            Spacer()
            StudioMenu(L10n.text("工程")) {
                Button(L10n.text("保存工程…")) { saveProject() }
                Button(L10n.text("打开工程…")) { openProject() }
            }.disabled(model.busy)
            Button(L10n.text("保存图片…")) { if let result = model.result { save(result) } }
                .disabled(model.busy || model.result == nil).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .task { model.detect() }.onDisappear { model.cancel() }
    }
    private func dimension(_ title: String, id: UUID, key: WritableKeyPath<CGRect, CGFloat>, value: CGFloat) -> some View {
        InspectorField(title: title + "（%）") {
            TextField(title, value: Binding(get: { Double(value) * 100 }, set: { value in model.change(id) { $0.bounds[keyPath: key] = CGFloat(value / 100) } }), format: .number.precision(.fractionLength(1)))
                .accessibilityLabel(title + L10n.text("百分比"))
        }
    }
    private func saveProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("教程布局.deskui"); panel.allowedContentTypes = [UTType(filenameExtension: "deskui") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }; model.saveProject(to: url)
    }
    private func openProject() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "deskui") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }; selected = nil; model.loadProject(from: url)
    }
}
