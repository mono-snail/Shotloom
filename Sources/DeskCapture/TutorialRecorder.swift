import AppKit
import SwiftUI
import ScreenCaptureKit
import ImageIO

struct TutorialStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail = ""
    var file: String
    var clickX: Double
    var clickY: Double
    var timestamp: Double? = nil
    var windowKey: String? = nil
    var parts: [TutorialFrame]? = nil
}
@MainActor
final class TutorialRecorder: ObservableObject {
    @Published var steps: [TutorialStep] = [] { didSet { unsavedChanges = true } }
    @Published private(set) var unsavedChanges = false
    @Published private(set) var busy = false
    @Published private(set) var running = false
    @Published var paused = false
    @Published var message: String?
    private(set) var directory: URL?
    private var monitor: Any?
    private var pending: [CGPoint] = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var lastClick = 0.0
    private var persistedData: Data?
    private var pendingSave: Task<Void, Never>?
    private var initialLoad: Task<Void, Never>?
    private var mergeUndo: [(before: [TutorialStep], after: [TutorialStep])] = []
    var canUndoMerge: Bool { mergeUndo.last.map { $0.after == steps } == true }
    var projectRoot: URL { root }
    var onFinish: (() -> Void)?
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? RecordingLibrary.directory.deletingLastPathComponent().appendingPathComponent("Tutorials", isDirectory: true)
        if root != nil {
            if let saved = TutorialPersistence.recent(self.root) { directory = saved.0; steps = saved.1; persistedData = saved.2 }
        } else {
            let root = self.root
            initialLoad = Task { [weak self] in
                let saved = await Task.detached(priority: .utility) { TutorialPersistence.recent(root) }.value
                guard let self, !self.running, self.directory == nil, self.steps.isEmpty, let saved else { return }
                self.directory = saved.0; self.steps = saved.1; self.persistedData = saved.2; self.unsavedChanges = false
            }
        }
    }
    func start() async throws {
        await initialLoad?.value
        await pendingSave?.value
        guard !running, !busy else { return }
        let token = UUID(); generation = token; running = true
        do { _ = try await CaptureEngine().content(); try Task.checkCancellation() }
        catch { if generation == token { running = false }; throw error }
        guard running, generation == token else { throw CancellationError() }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        directory = folder; steps = []; persistedData = nil; mergeUndo = []; pending = []; paused = false; message = nil
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.clicked(NSEvent.mouseLocation) }
        }
        guard monitor != nil else { running = false; throw CaptureError.message(L10n.text("无法监听点击，请重新开始。")) }
    }
    private func clicked(_ point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard running, !paused, now - lastClick > 0.4, steps.count < 100, pending.count < 20 else { return }
        lastClick = now; pending.append(point)
        guard worker == nil else { return }
        let token = generation
        worker = Task {
            defer { if token == generation { worker = nil } }
            while running && !Task.isCancelled && token == generation && !pending.isEmpty {
                let point = pending.removeFirst()
                do {
                    let engine = CaptureEngine(), content = try await engine.content()
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    let click = CGPoint(x: point.x, y: top - point.y)
                    let ids = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? UInt32 }
                    let ranks = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
                    guard let window = content.windows.filter({ $0.windowLayer == 0 && $0.frame.contains(click) && $0.frame.width > 100 && $0.frame.height > 80 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier }).min(by: { (ranks[$0.windowID] ?? .max) < (ranks[$1.windowID] ?? .max) }), let directory else { continue }
                    let image = try await engine.capture(window: window)
                    try Task.checkCancellation()
                    guard token == generation, running else { return }
                    let file = "step-\(UUID()).png", output = directory.appendingPathComponent(file)
                    try await Task.detached(priority: .userInitiated) {
                        let scale = min(1, 1600 / CGFloat(max(image.width, image.height)))
                        let reduced = try CaptureImageTransform.render(image, width: max(1, Int(CGFloat(image.width) * scale)), height: max(1, Int(CGFloat(image.height) * scale)))
                        try CaptureImageExport.png(reduced, to: output)
                    }.value
                    guard token == generation, running else { return }
                    steps.append(TutorialStep(title: L10n.text("步骤 \(steps.count + 1)：\(window.owningApplication?.applicationName ?? L10n.text("操作"))"), file: file,
                        clickX: min(1, max(0, (click.x - window.frame.minX) / window.frame.width)), clickY: min(1, max(0, 1 - (click.y - window.frame.minY) / window.frame.height)),
                        timestamp: ProcessInfo.processInfo.systemUptime, windowKey: "\(window.owningApplication?.processID ?? 0)-\(window.windowID)"))
                    save()
                    if steps.count >= 100 { message = L10n.text("已保存 100 个步骤，可以结束并导出。"); stop(); return }
                } catch { if token == generation, running, !Task.isCancelled { message = L10n.text("这次点击未捕获：\(error.localizedDescription)") } }
            }
        }
    }
    func stop(notify: Bool = true) {
        guard running || worker != nil || monitor != nil else { return }
        running = false; generation = UUID(); worker?.cancel(); worker = nil; pending = []; if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; save()
        if notify { onFinish?() }
    }
    func save() {
        guard let directory else { return }
        let snapshot = steps, previous = pendingSave
        pendingSave = Task {
            await previous?.value
            guard self.directory == directory else { return }
            let expected = persistedData
            do {
                let data = try await Task.detached(priority: .utility) { try TutorialPersistence.save(snapshot, directory: directory, expected: expected) }.value
                if self.directory == directory { persistedData = data; if steps == snapshot { unsavedChanges = false } }
            } catch { if self.directory == directory { message = L10n.text("保存步骤失败，修改仍在编辑器中：\(error.localizedDescription)") } }
        }
    }
    func move(_ id: UUID, by amount: Int) { guard let i = steps.firstIndex(where: { $0.id == id }), steps.indices.contains(i + amount) else { return }; steps.swapAt(i, i + amount); save() }
    func export(_ output: URL) async throws {
        await initialLoad?.value
        guard let directory, !steps.isEmpty else { throw CaptureError.message(L10n.text("还没有可导出的步骤。")) }
        let steps = steps
        let exporting = Task.detached(priority: .userInitiated) { try Self.exportSnapshot(steps, directory: directory, to: output) }
        try await withTaskCancellationHandler { try await exporting.value } onCancel: { exporting.cancel() }
    }
    func openImported(directory: URL, steps: [TutorialStep]) async throws {
        guard !running, !busy else { throw CaptureError.message(L10n.text("请先结束当前教程操作。")) }
        busy = true; defer { busy = false }
        await pendingSave?.value
        if unsavedChanges, let previousDirectory = self.directory {
            let snapshot = self.steps, expected = persistedData
            let saving = Task.detached(priority: .utility) { try TutorialPersistence.save(snapshot, directory: previousDirectory, expected: expected) }
            persistedData = try await withTaskCancellationHandler(operation: { try await saving.value }, onCancel: { saving.cancel() })
        }
        let data = try await Task.detached(priority: .utility) { try TutorialPersistence.data(directory) }.value
        try Task.checkCancellation(); self.directory = directory; self.steps = steps; persistedData = data; mergeUndo = []; unsavedChanges = false
    }
    func mergeNearby() async throws {
        guard !running, !busy, let directory else { return }
        busy = true; defer { busy = false }
        await pendingSave?.value
        let before = steps, expected = persistedData
        let worker = Task.detached(priority: .userInitiated) { () throws -> ([TutorialStep], Data)? in
            guard let index = try TutorialEditing.firstNearby(before, directory: directory) else { return nil }
            let merged = try TutorialEditing.merge(before, at: index)
            return (merged, try TutorialPersistence.save(merged, directory: directory, expected: expected))
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard let result else { message = L10n.text("没有找到同窗口、相近时间/位置且画面相似的相邻步骤。"); return }
        mergeUndo.append((before, result.0)); if mergeUndo.count > 20 { mergeUndo.removeFirst() }
        while mergeUndo.reduce(0, { $0 + TutorialEditing.approximateBytes($1.before) + TutorialEditing.approximateBytes($1.after) }) > 8_000_000 { mergeUndo.removeFirst() }
        steps = result.0; persistedData = result.1; unsavedChanges = false
        message = L10n.text("已合并一组相近点击，所有原始步骤图保留，可撤销合并。")
    }
    func undoMerge() async throws {
        guard !running, !busy, let directory, let last = mergeUndo.last, last.after == steps else { return }
        busy = true; defer { busy = false }; await pendingSave?.value
        let expected = persistedData
        let worker = Task.detached(priority: .utility) { try TutorialPersistence.save(last.before, directory: directory, expected: expected) }
        let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        mergeUndo.removeLast(); steps = last.before; persistedData = data; unsavedChanges = false
    }
    func splitGroup(_ id: UUID) async throws {
        guard !running, !busy, let directory else { return }
        busy = true; defer { busy = false }; await pendingSave?.value
        let before = steps, expected = persistedData
        let worker = Task.detached(priority: .utility) { () throws -> ([TutorialStep], Data) in
            let next = try TutorialEditing.split(before, id: id)
            return (next, try TutorialPersistence.save(next, directory: directory, expected: expected))
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        steps = result.0; persistedData = result.1; unsavedChanges = false
    }
    nonisolated static func exportSnapshot(_ steps: [TutorialStep], directory: URL, to output: URL) throws {
        try TutorialExporter.export(steps, directory: directory, to: output)
    }

}

struct TutorialEditorView: View {
    @ObservedObject var recorder: TutorialRecorder
    let start: () -> Void
    var openProject: (() -> Void)? = nil
    @State private var exporting = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar {
                StudioHeader(title: L10n.text("步骤教程"), symbol: "list.number", compact: true)
            } tools: {
                Button(L10n.text("打开项目…")) { openProject?() }.disabled(openProject == nil || recorder.running || recorder.busy || exporting)
                Button(L10n.text("新建录制"), action: start).disabled(recorder.running || recorder.busy || exporting)

            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
            if let message = recorder.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button(L10n.text("合并一组相近点击")) { run { try await recorder.mergeNearby() } }
                Button(L10n.text("撤销合并")) { run { try await recorder.undoMerge() } }.disabled(!recorder.canUndoMerge)
                Text(recorder.unsavedChanges ? L10n.text("有未保存修改") : L10n.text("已保存")).font(.caption).foregroundStyle(.secondary)
            }.disabled(recorder.running || recorder.busy || exporting || recorder.steps.isEmpty)
            if recorder.steps.isEmpty {
                StudioLibraryEmpty(title: L10n.text("还没有教程步骤"), symbol: "list.number") {
                    Button(L10n.text("新建录制"), action: start).buttonStyle(StudioButtonStyle(primary: true, command: true))
                        .disabled(recorder.running || recorder.busy || exporting)
                }
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($recorder.steps) { $step in
                        HStack(alignment: .top, spacing: 12) {
                            if let directory = recorder.directory { HistoryThumbnailView(url: directory.appendingPathComponent(step.file)).frame(width: 150, height: 100) }
                            VStack(alignment: .leading, spacing: 12) {
                                InspectorField(title: L10n.text("步骤标题")) { TextField(L10n.text("标题"), text: $step.title) }
                                InspectorField(title: L10n.text("说明")) { TextField(L10n.text("步骤说明"), text: $step.detail, axis: .vertical).lineLimit(2...4) }
                                if step.parts == nil {
                                    HStack(alignment: .top, spacing: 12) {
                                        InspectorField(title: L10n.text("标记 X")) { TextField("X", value: $step.clickX, format: .number) }
                                        InspectorField(title: L10n.text("标记 Y")) { TextField("Y", value: $step.clickY, format: .number) }
                                    }
                                }
                                if let parts = step.parts {
                                    Text(L10n.text("合并步骤保留\(parts.count)张原图，导出逐张呈现")).font(.caption)
                                    Button(L10n.text("拆分为独立步骤")) { run { try await recorder.splitGroup(step.id) } }
                                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                                        HStack {
                                            if let directory = recorder.directory { HistoryThumbnailView(url: directory.appendingPathComponent(part.file)).frame(width: 70, height: 50) }
                                            VStack(alignment: .leading, spacing: 8) {
                                                InspectorField(title: L10n.text("分图标题")) {
                                                    TextField(L10n.text("标题"), text: Binding(get: { step.parts?[index].title ?? "" }, set: { step.parts?[index].title = $0 }))
                                                }
                                                InspectorField(title: L10n.text("分图说明")) {
                                                    TextField(L10n.text("说明"), text: Binding(get: { step.parts?[index].detail ?? "" }, set: { step.parts?[index].detail = $0 }), axis: .vertical).lineLimit(1...3)
                                                }
                                                HStack {
                                                    InspectorField(title: L10n.text("标记 X")) { TextField("X", value: Binding(get: { step.parts?[index].clickX ?? 0.5 }, set: { step.parts?[index].clickX = $0 }), format: .number) }
                                                    InspectorField(title: L10n.text("标记 Y")) { TextField("Y", value: Binding(get: { step.parts?[index].clickY ?? 0.5 }, set: { step.parts?[index].clickY = $0 }), format: .number) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }.textFieldStyle(.roundedBorder)
                            VStack(spacing: 8) {
                                StudioIconButton(title: L10n.text("上移步骤"), symbol: "chevron.up") { recorder.move(step.id, by: -1) }.disabled(recorder.steps.first?.id == step.id)
                                StudioIconButton(title: L10n.text("下移步骤"), symbol: "chevron.down") { recorder.move(step.id, by: 1) }.disabled(recorder.steps.last?.id == step.id)
                                StudioIconButton(title: L10n.text("删除步骤"), symbol: "trash") { recorder.steps.removeAll { $0.id == step.id }; recorder.save() }
                            }
                        }.padding(16).modifier(StudioPaperSurface())
                    }
                }
            }
            .disabled(recorder.running || recorder.busy || exporting)
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StudioActionBar {
                if operation != nil { ProgressView().controlSize(.small); Button(L10n.text("取消操作")) { operation?.cancel() } }
                Spacer()
                StudioMenu(L10n.text("导出")) {
                    Button(L10n.text("HTML 或 PDF…")) { export() }
                    Button(L10n.text("可编辑项目（含原图）…")) { exportPackage(delivery: false) }
                    Button(L10n.text("交付文件夹（PDF、HTML、原图工程）…")) { exportPackage(delivery: true) }
                }.disabled(recorder.steps.isEmpty || exporting || recorder.running || recorder.busy)
                Button(L10n.text("保存修改")) { recorder.save() }.disabled(recorder.busy || exporting).buttonStyle(StudioButtonStyle(primary: true, command: true))
            }
        }.font(.system(size: 13)).controlSize(.small).frame(minWidth: StudioMetrics.workspaceMinimum.width, minHeight: StudioMetrics.workspaceMinimum.height)
            .foregroundStyle(Palette.white).background(Palette.ink)
            .buttonStyle(StudioButtonStyle(command: true))
            .onDisappear { operation?.cancel() }
    }
    private func run(_ work: @escaping () async throws -> Void) {
        guard operation == nil else { return }
        operation = Task { defer { operation = nil }; do { try await work() } catch { if !Task.isCancelled { recorder.message = error.localizedDescription } } }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf, .html]; panel.nameFieldStringValue = L10n.text("操作教程.pdf")
        panel.begin { result in guard result == .OK, let target = panel.url else { return }; exporting = true; run { defer { exporting = false }; try await recorder.export(target) } }
    }
    private func exportPackage(delivery: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = delivery ? [.folder] : [.deskTutorialProject]
        panel.nameFieldStringValue = delivery ? L10n.text("教程-交付") : L10n.text("教程.desktutorial"); panel.message = L10n.text("包含原始步骤图片与说明。已有目录不会覆盖。")
        panel.begin { response in
            guard response == .OK, let output = panel.url, let directory = recorder.directory else { return }
            let steps = recorder.steps; exporting = true
            run {
                defer { exporting = false }
                let worker = Task.detached(priority: .userInitiated) {
                    if delivery { try ProjectDelivery.tutorial(steps, directory: directory, to: output) }
                    else { try PortableProject.exportTutorial(steps, directory: directory, to: output) }
                }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                if !Task.isCancelled { recorder.message = L10n.text("教程项目已导出，包含原始步骤图") }
            }
        }
    }
}
struct TutorialHUD: View {
    @ObservedObject var recorder: TutorialRecorder
    var body: some View {
        HStack(spacing: 12) { Image(systemName: "list.number").foregroundStyle(Palette.ice); Text(L10n.text("\(recorder.steps.count) 个步骤")).font(.system(size: 12)); Button(recorder.paused ? L10n.text("继续") : L10n.text("暂停")) { recorder.paused.toggle() }; Button(L10n.text("完成")) { recorder.stop() } }.buttonStyle(.plain).padding(12).foregroundStyle(Palette.white).background(OpticalPanel(radius: 16))
    }
}
