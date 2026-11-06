import SwiftUI

@MainActor final class LocalWorkflowRun: ObservableObject {
    @Published private(set) var source: CGImage?
    @Published private(set) var result: LocalWorkflowResult?
    @Published private(set) var busy = false
    @Published private(set) var status = L10n.text("选择图片或捕获当前屏幕，然后运行流程。")
    @Published var error: String?
    private var token = UUID()
    private var task: Task<Void, Never>?
    private var cancelInput: (() -> Void)?
    @Published private(set) var reviewInput: LocalWorkflowReviewInput?
    private var reviewContinuation: CheckedContinuation<[CGRect], Error>?
    private func closeReview() {
        let continuation = reviewContinuation; reviewContinuation = nil; reviewInput = nil
        continuation?.resume(throwing: CancellationError())
    }
    func cancelReview() { if reviewInput != nil { cancel() } }
    func confirmReview(_ id: UUID, bounds: [CGRect], reviewed: Bool) {
        guard reviewed, reviewInput?.id == id, let continuation = reviewContinuation else { return }
        reviewContinuation = nil; reviewInput = nil
        continuation.resume(returning: bounds)
    }
    private func requestReview(_ input: LocalWorkflowReviewInput, generation: UUID) async throws -> [CGRect] {
        try Task.checkCancellation()
        guard generation == token, reviewInput == nil else { throw CancellationError() }
        status = L10n.text("流程已暂停：请复核候选和图片，再确认继续。")
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled || token != generation { continuation.resume(throwing: CancellationError()); return }
                reviewInput = input; reviewContinuation = continuation
            }
        }, onCancel: { [weak self] in Task { @MainActor in
            guard let self, self.token == generation, self.reviewInput?.id == input.id else { return }
            self.closeReview()
        } })
    }
    init(source: CGImage? = nil) { self.source = source }
    func cancel() { token = UUID(); closeReview(); let input = cancelInput; cancelInput = nil; input?(); task?.cancel(); task = nil; busy = false; status = L10n.text("已停止当前处理，原图保留。") }
    func changed() { cancel(); result = nil; status = L10n.text("步骤已改变，请重新运行。") }
    func load(_ url: URL) { loadImage { try CaptureImageRead.load(url) } }
    func loadExample() { loadImage { try WorkflowExampleImage.load() } }
    private func loadImage(_ decode: @escaping @Sendable () throws -> CGImage) {
        cancel(); busy = true; result = nil; error = nil
        let generation = token
        task = Task { [self] in
            let worker = Task.detached(priority: .userInitiated) { try decode() }
            do {
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, token == generation else { return }
                source = image; busy = false; status = L10n.text("图片已载入。")
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
    func captureScreen(recipe: LocalWorkflowRecipe? = nil, rules: [SensitiveRule] = []) {
        cancel(); busy = true; result = nil; error = nil
        let generation = token
        let displayID = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        task = Task { [self] in
            do {
                if let recipe {
                    let validation = Task.detached { try recipe.validate() }
                    try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
                    guard !Task.isCancelled, token == generation else { return }
                }
                guard let displayID else { throw CaptureError.message(L10n.text("当前没有可捕获的屏幕。")) }
                let engine = CaptureEngine(), content = try await engine.content()
                let snapshots = try await engine.snapshots(content: content, displayID: displayID)
                guard !Task.isCancelled, token == generation else { return }
                guard let image = snapshots.first?.image else { throw CaptureError.message(L10n.text("显示器已改变，请重新捕获。")) }
                source = image; busy = false; status = L10n.text("已捕获当前屏幕，待运行处理。")
                if let recipe { execute(recipe, rules: rules) }
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
    func captureSelection(_ mode: CaptureMode, app: AppCoordinator, recipe: LocalWorkflowRecipe? = nil, rules: [SensitiveRule] = []) {
        cancel(); busy = true; result = nil; error = nil
        let generation = token
        task = Task { [self, app] in
            do {
                if let recipe {
                    let validation = Task.detached { try recipe.validate() }
                    try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
                }
                guard !Task.isCancelled, token == generation else { return }
                let id = try app.pickWorkflowInput(mode) { [weak self] response in
                    guard let self, self.token == generation else { return }
                    self.cancelInput = nil; self.busy = false
                    switch response {
                    case .success(let image):
                        self.source = image; self.status = L10n.text("输入已选取。")
                        if let recipe { self.execute(recipe, rules: rules) }
                    case .failure(is CancellationError): self.status = L10n.text("已取消输入选择，原图保留。")
                    case .failure(let error): self.error = error.localizedDescription
                    }
                }
                cancelInput = { [weak app] in app?.cancelWorkflowInput(id) }
                status = mode == .window ? L10n.text("选择窗口并确认作为输入。") : L10n.text("框选区域并确认作为输入。")
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }

    func execute(_ recipe: LocalWorkflowRecipe, rules: [SensitiveRule] = [], reviewScanner: (@Sendable (CGImage, [SensitiveRule]) async throws -> [SensitiveReviewCandidate])? = nil, completion: ((LocalWorkflowResult) -> Void)? = nil) {
        guard let source else { error = L10n.text("请先选择图片或捕获屏幕。"); return }
        cancel(); busy = true; result = nil; error = nil
        let generation = token
        task = Task { [self] in
            do {
                let output = try await LocalWorkflowProcessor.run(source, recipe: recipe, progress: { [weak self] index, title in
                    await self?.progress(index, title: title, token: generation)
                }, rules: rules, review: { [weak self] input in
                    guard let self else { throw CancellationError() }
                    return try await self.requestReview(input, generation: generation)
                }, reviewScanner: reviewScanner)
                guard !Task.isCancelled, token == generation else { return }; result = output; busy = false; status = L10n.text("\(output.completedSteps) 步已完成。"); completion?(output)
            } catch { if token == generation { busy = false; self.error = error.localizedDescription } }
        }
    }
    private func progress(_ index: Int, title: String, token: UUID) { if token == self.token { status = L10n.text("第\(index + 1)步：\(title)") } }
}

struct LocalWorkflowView: View {
    @ObservedObject var app: AppCoordinator
    @StateObject private var run: LocalWorkflowRun
    @ObservedObject private var catalog = WorkflowCatalog.shared
    @StateObject private var delivery = WorkflowDelivery()
    @StateObject private var livePreview = WorkflowLivePreview()
    @StateObject private var sensitiveRules = SensitiveRuleStore()
    @State private var recipe: LocalWorkflowRecipe
    @State private var brands: [TutorialPreset] = []
    @State private var baseline: LocalWorkflowRecipe
    @State private var expandedStep: UUID?
    @State private var error: String?
    @State private var savedMessage: String?
    @State private var libraryBusy = false
    @State private var libraryTask: Task<Void, Never>?
    @State private var showingSensitiveRules = false
    @State private var showSource = false
    @State private var started = false
    @State private var confirmingClose = false
    @State private var confirmingSwitch = false
    @State private var pendingRecipe: LocalWorkflowRecipe?
    @State private var sourcePanel: NSOpenPanel?
    @State private var filePanel: NSSavePanel?
    @State private var folderPanel: NSOpenPanel?
    @State private var visible = true
    let usesExample: Bool
    let runOnOpen: Bool
    var parent: () -> NSWindow? = { nil }
    let close: () -> Void

    init(app: AppCoordinator, recipe: LocalWorkflowRecipe, source: CGImage? = nil, runOnOpen: Bool = false,
         parent: @escaping () -> NSWindow? = { nil }, close: @escaping () -> Void) {
        self.app = app; self.close = close; self.runOnOpen = runOnOpen; self.parent = parent
        usesExample = source == nil
        _recipe = State(initialValue: recipe); _baseline = State(initialValue: recipe)
        _expandedStep = State(initialValue: recipe.steps.first?.id)
        _run = StateObject(wrappedValue: LocalWorkflowRun(source: source))
    }
    private var busy: Bool { run.busy || libraryBusy || delivery.state.busy || sourcePanel != nil || filePanel != nil || folderPanel != nil }
    private var savedCurrent: Bool { catalog.recipes.contains { $0 == recipe } }
    private var output: Binding<WorkflowOutput> {
        Binding(get: { recipe.delivery }, set: { recipe.output = $0 })
    }
    private var workflowIcon: Binding<String> {
        Binding(get: { recipe.toolbarSymbol }, set: { recipe.iconName = $0; recipe.inCaptureToolbar = true })
    }
    private var pinned: Binding<Bool> {
        Binding(get: { recipe.inCaptureToolbar == true }, set: { recipe.inCaptureToolbar = $0 })
    }
    private var unavailableRules: Bool { sensitiveRules.loadError != nil && recipe.steps.contains { $0.kind == .sensitiveReview } }

    var body: some View {
        StudioWorkspace(title: L10n.text("流程"), symbol: "point.3.connected.trianglepath.dotted") {
            StudioMenu(recipe.name.count > 12 ? String(recipe.name.prefix(12)) + "…" : recipe.name) {
                ForEach(catalog.recipes) { value in Button { requestRecipe(value) } label: { Label(value.name, systemImage: value.toolbarSymbol) } }
                if catalog.recipes.isEmpty { Text(L10n.text("暂无已保存流程")) }
            }.disabled(busy)
            StudioMenu(L10n.text("新建")) {
                Button(L10n.text("空白流程")) { requestRecipe(Self.newRecipe()) }
                Divider()
                Group {
                    Button(L10n.text("水印 → 美化 → 保存")) { requestRecipe(Self.watermarkRecipe()) }
                    Button(L10n.text("缩小 → 复制")) {
                        var value = Self.newRecipe(); value.name = L10n.text("缩小截图"); value.steps = [.configured(.resize)]; requestRecipe(value)
                    }
                    Button(L10n.text("识别 → 复制文字")) {
                        var value = Self.newRecipe(); value.name = L10n.text("提取文字"); value.steps = [.configured(.ocr)]
                        value.output = .init(kind: .copyText); requestRecipe(value)
                    }
                }
            }.disabled(busy)
            Button(L10n.text("保存流程"), action: saveRecipe).disabled(busy || savedCurrent).keyboardShortcut("s", modifiers: .command)
                .buttonStyle(StudioButtonStyle(primary: !savedCurrent, command: true))
            StudioMenu(L10n.text("更多")) {
                Button(L10n.text("另存为新流程")) {
                    var value = recipe; value.id = UUID(); value.name = String((value.name + L10n.text(" 副本")).prefix(40)); value.inCaptureToolbar = false
                    requestRecipe(value)
                }
                Button(L10n.text("导入流程…"), action: importRecipe)
                Button(L10n.text("导出流程…"), action: exportRecipe)
                Button(L10n.text("编辑敏感规则…")) { showingSensitiveRules = true }
                Button(L10n.text("复制流程链接")) { app.copyText("\(AppDistribution.urlScheme)://workflow?id=\(recipe.id)") }
                    .disabled(!catalog.recipes.contains { $0.id == recipe.id })
                Menu(L10n.text("处理结果")) {
                    Button(L10n.text("复制图片")) { deliverResult(.init(kind: .copyImage)) }
                    Button(L10n.text("保存图片…")) { deliverResult(.init(kind: .saveImage)) }
                    Button(L10n.text("复制文字")) { deliverResult(.init(kind: .copyText)) }.disabled(run.result?.text == nil)
                    Button(L10n.text("保存文字…")) { deliverResult(.init(kind: .saveText)) }.disabled(run.result?.text == nil)
                    Button(L10n.text("加入历史")) {
                        if let result = run.result { libraryWork { _ = try await app.store.addAsync(result.image, mode: .region) } }
                    }
                }.disabled(run.result == nil)
                Divider()
                Button(L10n.text("删除当前流程"), role: .destructive) { confirmingDelete = true }
                    .disabled(!catalog.recipes.contains { $0.id == recipe.id })
            }.disabled(busy)
        } preview: {
            preview
        } inspector: {
            configuration.disabled(busy)
        } actions: {
            if run.busy {
                ProgressView().controlSize(.small)
                Text(run.status).foregroundStyle(Palette.muted)
                Button(L10n.text("取消")) { run.cancel() }
            } else if delivery.state.busy || delivery.state.hasResult {
                StudioImageDeliveryStatus(state: delivery.state, cancel: { delivery.cancel() })
            } else if livePreview.updating {
                ProgressView().controlSize(.small)
                Text(L10n.text("正在更新预览…")).foregroundStyle(Palette.muted)
                Button(L10n.text("取消预览")) { livePreview.cancel() }
            } else if let savedMessage { Text(savedMessage).foregroundStyle(Palette.muted) }
            else if run.result != nil { Text(run.status).foregroundStyle(Palette.muted) }
            else if livePreview.image != nil, livePreview.error == nil {
                Text(livePreview.isCurrent ? L10n.text("预览已更新") : L10n.text("预览已暂停")).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button(usesExample ? L10n.text("试运行") : L10n.text("运行流程")) { execute(deliver: !usesExample) }.disabled(busy || run.source == nil || unavailableRules)
                .buttonStyle(StudioButtonStyle(primary: true, command: true)).keyboardShortcut(.return, modifiers: .command)
        }
        .task {
            if run.source == nil { run.loadExample() }
            await catalog.refresh()
            do { brands = try await TutorialPresetLibrary.shared.list() }
            catch { /* Existing embedded presets and direct parameters remain usable. */ }
            guard visible, !started else { return }; started = true
            if runOnOpen { execute(deliver: !usesExample) }
        }
        .sheet(isPresented: $showingSensitiveRules) { SensitiveRulesEditorView(store: sensitiveRules) }
        .sheet(item: Binding(get: { run.reviewInput }, set: { if $0 == nil { run.cancelReview() } })) { input in
            WorkflowSensitiveReviewView(input: input, cancel: { run.cancelReview() },
                confirm: { run.confirmReview(input.id, bounds: $0, reviewed: true) })
        }
        .confirmationDialog(L10n.text("保存当前流程的更改？"), isPresented: $confirmingSwitch) {
            Button(L10n.text("保存并切换")) { saveRecipe(switchAfter: pendingRecipe) }
            Button(L10n.text("放弃更改"), role: .destructive) { if let pendingRecipe { loadRecipe(pendingRecipe) } }
            Button(L10n.text("取消"), role: .cancel) { pendingRecipe = nil }
        }
        .confirmationDialog(L10n.text("保存流程的更改？"), isPresented: $confirmingClose) {
            Button(L10n.text("保存并关闭")) { saveRecipe(switchAfter: nil, closeAfter: true) }
            Button(L10n.text("不保存关闭"), role: .destructive, action: close)
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .confirmationDialog(L10n.text("删除“\(recipe.name)”？"), isPresented: $confirmingDelete) {
            Button(L10n.text("删除流程"), role: .destructive) {
                let id = recipe.id
                libraryWork { try await LocalWorkflowLibrary.shared.remove(id); loadRecipe(Self.newRecipe()) }
            }
        }
        .onChange(of: recipe.steps) { _, _ in
            run.changed(); delivery.invalidate(); savedMessage = nil; error = nil; showSource = false
            livePreview.update(source: run.source, steps: recipe.steps)
        }
        .onChange(of: run.source.map(ObjectIdentifier.init)) { _, _ in
            showSource = false; livePreview.update(source: run.source, steps: recipe.steps)
        }
        .onChange(of: recipe.output) { _, _ in delivery.invalidate(); savedMessage = nil; error = nil }
        .onChange(of: recipe.name) { _, _ in savedMessage = nil }
        .onChange(of: recipe.inCaptureToolbar) { _, _ in savedMessage = nil }
        .onChange(of: recipe.iconName) { _, _ in savedMessage = nil }
        .onChange(of: sensitiveRules.revision) { _, _ in
            run.changed(); delivery.invalidate(); livePreview.update(source: run.source, steps: recipe.steps)
        }
        .onAppear {
            visible = true
            livePreview.update(source: run.source, steps: recipe.steps)
            (parent() as? LocalWorkflowWindow)?.shouldCloseRequest = {
                if recipe != baseline { confirmingClose = true; return false }
                return true
            }
        }
        .onDisappear {
            visible = false; run.cancel(); livePreview.cancel(); delivery.invalidate(); libraryTask?.cancel()
            sourcePanel?.cancel(nil); filePanel?.cancel(nil); folderPanel?.cancel(nil)
        }
    }
    @State private var confirmingDelete = false

    private var preview: some View {
        VStack(spacing: 16) {
            if let image = showSource ? run.source : (run.result?.image ?? livePreview.image ?? run.source) {
                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    if usesExample { Text(L10n.text("示例预览")).foregroundStyle(Palette.muted) }
                    Spacer()
                    Toggle(L10n.text("对照原图"), isOn: $showSource).fixedSize()
                }
            } else {
                VStack(spacing: 16) {
                    if run.busy { ProgressView(L10n.text("正在载入示例图片…")) }
                    else {
                        Image(systemName: "photo").font(.system(size: 36, weight: .light)).foregroundStyle(Palette.muted)
                        Button(L10n.text("重新载入示例图片")) { run.loadExample() }.disabled(busy)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let text = run.result?.text {
                DisclosureGroup(L10n.text("文字结果")) {
                    TextEditor(text: .constant(String(text.prefix(4000)))).font(.system(size: 13)).frame(height: 110)
                }
            }
            if run.result == nil, !run.busy, let message = livePreview.error {
                StudioMessage(text: L10n.text("预览未更新：\(message)"), kind: .error)
            }
            if run.result == nil, !livePreview.updating, livePreview.error == nil {
                ForEach(livePreview.deferredTools, id: \.self) { Text($0).foregroundStyle(Palette.muted) }
            }
            if let value = error ?? run.error ?? delivery.state.error {
                StudioMessage(text: value, kind: .error, dismiss: {
                    error = nil; run.error = nil; delivery.feedback.dismissError()
                })
            }
            if let value = (unavailableRules ? sensitiveRules.loadError : nil) ?? catalog.error {
                StudioMessage(text: value, kind: .error)
            }
            if let url = delivery.state.savedURL { StudioExportReceipt(url: url) }
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorControlGrid {
            InspectorField(title: L10n.text("名称")) {
                TextField(L10n.text("名称"), text: $recipe.name)
                    .onChange(of: recipe.name) { _, name in if name.count > 40 { recipe.name = String(name.prefix(40)) } }
            }
            InspectorField(title: L10n.text("图标")) { WorkflowIconPicker(selection: workflowIcon) }
            }
            Toggle(L10n.text("加入截图工具栏"), isOn: pinned).toggleStyle(InspectorToggleStyle())
            HStack {
                Text(L10n.text("处理步骤")).fontWeight(.semibold)
                Spacer()
                StudioMenu(L10n.text("添加工具")) {
                    ForEach(LocalWorkflowStep.Kind.allCases) { kind in
                        Button(kind.title) { add(kind) }
                            .disabled((kind == .sensitiveReview || kind == .ocr) && recipe.steps.contains { $0.kind == kind })
                    }
                }.disabled(recipe.steps.count >= 12)
            }
            if recipe.steps.isEmpty { Text(L10n.text("尚未添加工具")).foregroundStyle(Palette.muted) }
            ForEach($recipe.steps) { $step in
                let index = recipe.steps.firstIndex { $0.id == step.id } ?? 0
                VStack(alignment: .leading, spacing: 12) {
                    WorkflowStepHeader(step: step, number: index + 1,
                        expanded: Binding(get: { expandedStep == step.id }, set: { expandedStep = $0 ? step.id : nil }),
                        canMoveUp: index > 0, canMoveDown: index < recipe.steps.count - 1,
                        unavailable: recipe.steps.filter { $0.id != step.id }.map(\.kind),
                        replace: { replace(step.id, with: $0) }, moveUp: { move(step.id, by: -1) },
                        moveDown: { move(step.id, by: 1) }, remove: { recipe.steps.removeAll { $0.id == step.id } })
                    if expandedStep == step.id {
                        WorkflowStepFields(step: $step, brands: brands, chooseBrand: { useBrand($0, stepID: step.id) })
                            .padding(.horizontal, 4).padding(.bottom, 8)
                    }
                    Divider()
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let source = UUID(uuidString: raw), source != step.id,
                          let from = recipe.steps.firstIndex(where: { $0.id == source }),
                          let to = recipe.steps.firstIndex(where: { $0.id == step.id }) else { return false }
                    let item = recipe.steps.remove(at: from); recipe.steps.insert(item, at: to); return true
                }
            }
            InspectorGroup(L10n.text("输出"), initiallyExpanded: true) {
                WorkflowOutputFields(value: output, hasText: recipe.steps.last?.kind == .ocr, chooseFolder: chooseFolder)
            }
        }.environment(\.compactInspectorControls, true)
    }

    private func execute(deliver: Bool) {
        guard !busy, !unavailableRules, visible else { return }
        livePreview.cancel(); delivery.invalidate(); savedMessage = nil; showSource = false; error = nil
        let snapshot = recipe, clipboard = app.workflowClipboardRevision
        run.execute(snapshot, rules: sensitiveRules.rules, completion: { result in
            guard visible, recipe == snapshot else { return }
            if deliver { delivery.perform(snapshot.delivery, result: result, app: app, expectedClipboard: clipboard, parent: parent()) }
        })
    }
    private func deliverResult(_ output: WorkflowOutput) {
        guard let result = run.result, !busy else { return }
        delivery.perform(output, result: result, app: app, expectedClipboard: app.workflowClipboardRevision, parent: parent())
    }
    private func useBrand(_ preset: TutorialPreset, stepID: UUID) {
        libraryWork {
            let worker = Task.detached(priority: .userInitiated) { try preset.encoded() }
            let data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard visible, !Task.isCancelled, let index = recipe.steps.firstIndex(where: { $0.id == stepID }) else { return }
            recipe.steps[index].appearance = nil; recipe.steps[index].presetData = data
        }
    }
    private func replace(_ id: UUID, with kind: LocalWorkflowStep.Kind) {
        guard let index = recipe.steps.firstIndex(where: { $0.id == id }), recipe.steps[index].kind != kind else { return }
        var step = LocalWorkflowStep.configured(kind); step.id = id
        recipe.steps[index] = step; expandedStep = id
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = recipe.steps.firstIndex(where: { $0.id == id }), recipe.steps.indices.contains(index + offset) else { return }
        recipe.steps.swapAt(index, index + offset)
    }
    private func add(_ kind: LocalWorkflowStep.Kind) {
        let step = LocalWorkflowStep.configured(kind)
        // Keep recognition last and image transforms before any privacy review.
        let index = kind == .ocr ? recipe.steps.count : recipe.steps.firstIndex { $0.kind == .ocr || (kind != .sensitiveReview && $0.kind == .sensitiveReview) } ?? recipe.steps.count
        recipe.steps.insert(step, at: index); expandedStep = step.id
    }
    private func requestRecipe(_ value: LocalWorkflowRecipe) {
        if recipe != baseline { pendingRecipe = value; confirmingSwitch = true } else { loadRecipe(value) }
    }
    private func loadRecipe(_ value: LocalWorkflowRecipe) {
        recipe = value; baseline = value; expandedStep = value.steps.first?.id; pendingRecipe = nil
        run.changed(); delivery.invalidate(); error = nil; savedMessage = nil
        livePreview.update(source: run.source, steps: value.steps)
    }
    private func saveRecipe() { saveRecipe(switchAfter: nil) }
    private func saveRecipe(switchAfter next: LocalWorkflowRecipe?, closeAfter: Bool = false) {
        var snapshot = recipe; snapshot.version = 2
        libraryWork {
            try await LocalWorkflowLibrary.shared.save(snapshot)
            if let next { loadRecipe(next) }
            else { recipe = snapshot; baseline = snapshot; savedMessage = snapshot.inCaptureToolbar == true ? L10n.text("已保存到截图工具栏") : L10n.text("流程已保存") }
            if closeAfter { close() }
        }
    }
    private func libraryWork(_ work: @escaping @MainActor () async throws -> Void) {
        guard !libraryBusy, visible else { return }; libraryBusy = true; error = nil
        libraryTask = Task {
            defer { libraryBusy = false; libraryTask = nil }
            do { try await work(); try Task.checkCancellation(); await catalog.refresh() }
            catch let failure { if !Task.isCancelled, visible { self.error = failure.localizedDescription } }
        }
    }
    private func importRecipe() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; sourcePanel = panel
        panel.begin { response in
            guard sourcePanel === panel else { return }; sourcePanel = nil
            guard visible, response == .OK, let url = panel.url else { return }
            libraryWork {
                let imported = try await LocalWorkflowLibrary.shared.importFile(url)
                requestRecipe(imported)
            }
        }
    }
    private func exportRecipe() {
        guard !busy else { return }
        var snapshot = recipe
        snapshot.output?.directoryBookmark = nil; snapshot.output?.directoryName = nil
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(recipe.name).deskflow"; filePanel = panel
        SavePanelPresentation.begin(panel, parent: parent()) { response in
            guard filePanel === panel else { return }; filePanel = nil
            guard visible, response == .OK, let url = panel.url else { return }
            libraryWork {
                let worker = Task.detached { try LocalWorkflowFiles.write(LocalWorkflowLibrary.encode(snapshot), to: url) }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            }
        }
    }
    private func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        folderPanel = panel
        panel.begin { response in
            guard folderPanel === panel else { return }; folderPanel = nil
            guard visible, response == .OK, let url = panel.url else { return }
            do {
                var value = recipe.delivery
                value.directoryBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                value.directoryName = url.lastPathComponent; recipe.output = value
            } catch { self.error = error.localizedDescription }
        }
    }
    static func newRecipe() -> LocalWorkflowRecipe {
        var value = LocalWorkflowRecipe(); value.name = L10n.text("我的流程"); value.steps = []; value.output = .init()
        value.inCaptureToolbar = true; value.iconName = "bolt.fill"
        return value
    }
    static func watermarkRecipe() -> LocalWorkflowRecipe {
        var value = newRecipe(); value.name = L10n.text("发布截图"); value.steps = [.configured(.watermark), .configured(.beautify)]
        value.output = .init(kind: .saveImage); value.iconName = "seal.fill"; return value
    }
}
