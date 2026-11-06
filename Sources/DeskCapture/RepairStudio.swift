import SwiftUI
import UniformTypeIdentifiers

enum RepairPreviewBackground: String, CaseIterable, Identifiable {
    case checkerboard, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .checkerboard: L10n.text("棋盘格"); case .light: L10n.text("浅色"); case .dark: L10n.text("深色") } }
}

@MainActor
final class RepairStudioModel: ObservableObject {
    let original: CGImage
    @Published private(set) var image: CGImage
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var models: [StoredRepairModel] = []
    @Published private(set) var subjects: [ForegroundSubject] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private struct State {
        let image: CGImage
        let subjectComposition: RepairSubjectComposition?
    }
    private var subjectComposition: RepairSubjectComposition?
    private let foregroundAnalysis: ForegroundSubjectAnalysis
    private var undoStates: [State] = [], redoStates: [State] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var subjectMaskForDiagnostics: (@Sendable (CGImage, IndexSet) throws -> RepairRasterMask)?
    var pendingTaskForDiagnostics: Task<Void, Never>? { task }
    private var state: State { .init(image:image,subjectComposition:subjectComposition) }
    init(image: CGImage) { original=image;self.image=image;foregroundAnalysis=ForegroundSubjectAnalysis(source:image) }
    func cancel() { generation=UUID();task?.cancel();task=nil;busy=false }
    func refreshModels() { Task { do { models=try await RepairModelLibrary.shared.list() } catch { self.error=error.localizedDescription } } }
    func importModel(_ url: URL) {
        start { [weak self] in
            _ = try await RepairModelLibrary.shared.importModel(from:url,provenance:L10n.text("用户导入的本地模型；本应用不随包分发此权重。"))
            self?.models=try await RepairModelLibrary.shared.list()
            return nil
        }
    }
    func removeModel(_ id: UUID) {
        start { [weak self] in try await RepairModelLibrary.shared.remove(id); self?.models=try await RepairModelLibrary.shared.list();return nil }
    }
    func repair(_ selection: RepairSelection, method: LocalRepairMethod, anchor: CGPoint?, modelID: UUID?, context: RepairModelContext = .nearby, blendBoundaryColors: Bool = false) {
        let base=image,source=original,composition=subjectComposition
        start {
            let result=try await LocalImageRepair.renderWithMask(base:base,original:source,selection:selection,method:method,anchor:anchor,modelID:modelID,modelContext:context,blendBoundaryColors:blendBoundaryColors)
            var updated: RepairSubjectComposition?
            if let composition {
                let worker=Task.detached(priority:.userInitiated) { try composition.addingOverride(image:result.image,mask:result.mask) }
                updated=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            }
            return State(image:result.image,subjectComposition:updated)
        }
    }
    func findSubjects() {
        let analysis=foregroundAnalysis
        start { [weak self] in
            let result=try await analysis.subjects()
            try Task.checkCancellation();self?.subjects=result;return nil
        }
    }
    func background(_ selected: Set<Int>) {
        guard !selected.isEmpty,selected.allSatisfy({ $0 > 0 && $0 < NSNotFound }) else {
            cancel();error=L10n.text("请选择有效的主体编号。");return
        }
        let source=original,composition=subjectComposition ?? RepairSubjectComposition(base:image)
        let provider=subjectMaskForDiagnostics, analysis=foregroundAnalysis
        start {
            let mask: RepairRasterMask
            if let provider {
                let worker=Task.detached(priority:.userInitiated) { try provider(source,IndexSet(selected)) }
                mask=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            } else { mask=try await analysis.erasure(instances:IndexSet(selected)) }
            try Task.checkCancellation()
            let worker=Task.detached(priority:.userInitiated) {
                try Task.checkCancellation()
                return try composition.applying(mask)
            }
            let output=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            return State(image:output,subjectComposition:composition)
        }
    }
    private func start(_ operation: @escaping @MainActor () async throws -> State?) {
        cancel();let token=generation;busy=true;error=nil
        task=Task {
            do {
                let output=try await operation()
                guard !Task.isCancelled,generation==token else { return }
                if let output { undoStates.append(state);redoStates.removeAll();restore(output);prune() }
            } catch is CancellationError { }
            catch { if generation==token { self.error=error.localizedDescription } }
            if generation==token { busy=false;task=nil;updateUndo() }
        }
    }
    private func restore(_ state: State) { image=state.image;subjectComposition=state.subjectComposition }
    func undo() { cancel();guard let value=undoStates.popLast() else{return};redoStates.append(state);restore(value);updateUndo() }
    func redo() { cancel();guard let value=redoStates.popLast() else{return};undoStates.append(state);restore(value);prune();updateUndo() }
    func reset() { cancel();undoStates.append(state);image=original;subjectComposition=nil;redoStates.removeAll();prune();updateUndo() }
    private func prune() {
        func retainedBytes() -> Double {
            var seen=Set<ObjectIdentifier>(), bytes:Double=0
            for state in undoStates {
                for image in [state.image] + (state.subjectComposition?.retainedImages ?? []) where seen.insert(ObjectIdentifier(image)).inserted {
                    bytes += Double(image.bytesPerRow)*Double(image.height)
                }
                bytes += Double(state.subjectComposition?.overrides?.values.count ?? 0)
            }
            return bytes
        }
        while undoStates.count>1 && retainedBytes()>128_000_000 { undoStates.removeFirst() }
    }
    private func updateUndo() { canUndo = !undoStates.isEmpty;canRedo = !redoStates.isEmpty }
}

struct RepairStudioView: View {
    @StateObject private var model: RepairStudioModel
    let save: (CGImage) -> Void
    let close: () -> Void
    @State private var selection=RepairSelection()
    @State private var method=LocalRepairMethod.texture
    @State private var diameter:CGFloat=40
    @State private var erasing=false
    @State private var active:RepairStroke?
    @State private var anchor:CGPoint?
    @State private var choosingAnchor=false
    @State private var selectedModel:UUID?
    @State private var modelContext=RepairModelContext.nearby
    @State private var blendBoundaryColors=false
    @State private var selectedSubjects=Set<Int>()
    @State private var showOriginal=false
    @State private var showSelection=true
    @State private var previewBackground=RepairPreviewBackground.checkerboard
    init(image: CGImage, save: @escaping (CGImage) -> Void, close: @escaping () -> Void) {
        _model=StateObject(wrappedValue:RepairStudioModel(image:image));self.save=save;self.close=close
    }
    var body: some View {
        StudioWorkspace(title: L10n.text("图像修复"), symbol: "paintbrush.pointed") {
            Toggle(L10n.text("对照原图"), isOn: $showOriginal)
            StudioIconButton(title: L10n.text("关闭"), symbol: "xmark") { model.cancel(); close() }
        } preview: {
            VStack(spacing: 12) {
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                if choosingAnchor { Label(L10n.text("选择取样位置"), systemImage: "scope").foregroundStyle(Palette.ice) }
            }
        } inspector: {
            InspectorGroup(L10n.text("修复方式"), initiallyExpanded: true) {
                InspectorField(title: L10n.text("方式")) { Picker(L10n.text("方式"), selection: $method) { ForEach(LocalRepairMethod.allCases) { Text($0.title).tag($0) } }.labelsHidden() }.labelsHidden()
                if method == .clone {
                    Button(anchor == nil ? L10n.text("选择取样点") : L10n.text("更换取样点")) { choosingAnchor = true }
                }
                if method == .texture { Toggle(L10n.text("融合边界颜色"), isOn: $blendBoundaryColors) }
                if method == .model {
                    InspectorField(title: L10n.text("模型")) { Picker(L10n.text("模型"), selection: $selectedModel) {
                        Text(L10n.text("选择模型")).tag(Optional<UUID>.none)
                        ForEach(model.models) { item in Text(item.name).tag(Optional(item.id)) }
                    }.labelsHidden() }
                    InspectorField(title: L10n.text("参考范围")) { Picker(L10n.text("参考范围"), selection: $modelContext) {
                        ForEach(RepairModelContext.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden() }
                    StudioMenu(L10n.text("管理模型")) {
                        Button(L10n.text("导入模型…"), action: importModel)
                        if let id = selectedModel {
                            Button(L10n.text("移到废纸篓"), role: .destructive) { model.removeModel(id); selectedModel = nil }
                        }
                    }
                }
            }
            InspectorGroup(L10n.text("画笔与选区"), initiallyExpanded: true) {
                Toggle(L10n.text("擦除选区"), isOn: $erasing)
                InspectorSlider(title: L10n.text("画笔大小"), value: Binding(get: { Double(diameter) }, set: { diameter = CGFloat($0) }), range: 1...200, unit: " px")
                InspectorSlider(title: L10n.text("边缘融合"), value: Binding(get: { Double(selection.feather) }, set: { selection.feather = CGFloat($0) }), range: 0...32, unit: " px")
                Toggle(L10n.text("显示选区"), isOn: $showSelection)
                HStack {
                    Button(L10n.text("撤回笔画")) { if !selection.strokes.isEmpty { selection.strokes.removeLast() } }.disabled(selection.strokes.isEmpty)
                    Button(L10n.text("清空")) { selection.strokes.removeAll() }.disabled(selection.strokes.isEmpty)
                }
                Button(L10n.text("修复选区")) { showOriginal = false; model.repair(selection, method: method, anchor: anchor, modelID: selectedModel, context: modelContext, blendBoundaryColors: blendBoundaryColors) }
                    .disabled(model.busy || selection.strokes.isEmpty || (method == .model && selectedModel == nil))
            }
            InspectorGroup(L10n.text("主体抠图")) {
                Button(L10n.text("识别主体")) { model.findSubjects() }.disabled(model.busy)
                ForEach(model.subjects) { subject in
                    Toggle(isOn: Binding(get: { selectedSubjects.contains(subject.id) }, set: { if $0 { selectedSubjects.insert(subject.id) } else { selectedSubjects.remove(subject.id) } })) {
                        HStack {
                            Image(decorative: subject.preview, scale: 1).resizable().scaledToFit().frame(width: 52, height: 40)
                            Text(L10n.text("主体 \(subject.id)"))
                        }
                    }.toggleStyle(.checkbox)
                }
                if !model.subjects.isEmpty {
                    Button(L10n.text("保留所选主体")) { showOriginal = false; model.background(selectedSubjects) }.disabled(model.busy || selectedSubjects.isEmpty)
                }
            }
            InspectorGroup(L10n.text("画布显示")) {
                InspectorField(title: L10n.text("透明区域")) { Picker(L10n.text("透明区域"), selection: $previewBackground) { ForEach(RepairPreviewBackground.allCases) { Text($0.title).tag($0) } }.labelsHidden() }
            }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } actions: {
            StudioIconButton(title: L10n.text("撤销"), symbol: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo || model.busy)
            StudioIconButton(title: L10n.text("重做"), symbol: "arrow.uturn.forward") { model.redo() }.disabled(!model.canRedo || model.busy)
            Button(L10n.text("恢复原图")) { model.reset() }.disabled(model.busy)
            Spacer()
            if model.busy { ProgressView().controlSize(.small); Button(L10n.text("取消处理")) { model.cancel() } }
            Button(L10n.text("保存副本…")) { save(model.image) }.disabled(model.busy).buttonStyle(StudioButtonStyle(primary: true, command: true))
        }
            .onAppear { model.refreshModels() }
            .onChange(of:selection) { _,_ in model.cancel() }
            .onChange(of:method) { _,_ in model.cancel() }
            .onChange(of:anchor) { _,_ in model.cancel() }
            .onChange(of:selectedModel) { _,_ in model.cancel() }
            .onChange(of:modelContext) { _,_ in model.cancel() }
            .onChange(of:blendBoundaryColors) { _,_ in model.cancel() }
            .onChange(of:selectedSubjects) { _,_ in model.cancel() }
            .onChange(of:model.subjects.map(\.id)) { _,ids in selectedSubjects=Set(ids) }
            .onChange(of:model.models.map(\.id)) { _,ids in if selectedModel == nil { selectedModel=ids.first } }
            .onDisappear { model.cancel() }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            let displayed=showOriginal ? model.original : model.image
            let scale=min(geometry.size.width/CGFloat(displayed.width),geometry.size.height/CGFloat(displayed.height))
            let size=CGSize(width:CGFloat(displayed.width)*scale,height:CGFloat(displayed.height)*scale)
            let origin=CGPoint(x:(geometry.size.width-size.width)/2,y:(geometry.size.height-size.height)/2)
            ZStack {
                Color.gray.opacity(0.18)
                previewBacking.frame(width:size.width,height:size.height).position(x:geometry.size.width/2,y:geometry.size.height/2)
                Image(nsImage:NSImage(cgImage:displayed,size:.zero)).resizable().frame(width:size.width,height:size.height).position(x:geometry.size.width/2,y:geometry.size.height/2)
                Canvas { context,_ in
                    for stroke in selection.strokes + (active.map{[$0]} ?? []) {
                        context.blendMode=stroke.erase ? .destinationOut : .normal
                        var path=Path()
                        let points=stroke.points.map{CGPoint(x:origin.x+$0.x*size.width,y:origin.y+$0.y*size.height)}
                        if points.count==1,let point=points.first {
                            let radius=stroke.diameter*scale/2;path.addEllipse(in:CGRect(x:point.x-radius,y:point.y-radius,width:2*radius,height:2*radius))
                            context.fill(path,with:.color(.green))
                        } else if let first=points.first {
                            path.move(to:first);for point in points.dropFirst(){path.addLine(to:point)}
                            context.stroke(path,with:.color(.green),style:StrokeStyle(lineWidth:stroke.diameter*scale,lineCap:.round,lineJoin:.round))
                        }
                    }
                }.compositingGroup().opacity(showSelection ? 0.4 : 0).allowsHitTesting(false)
                if let anchor {
                    Image(systemName:"scope").foregroundStyle(.blue).position(x:origin.x+anchor.x*size.width,y:origin.y+anchor.y*size.height)
                }
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0)
                .onChanged { event in
                    guard CGRect(origin:origin,size:size).contains(event.startLocation) else{return}
                    let point=CGPoint(x:max(0,min(1,(event.location.x-origin.x)/size.width)),y:max(0,min(1,(event.location.y-origin.y)/size.height)))
                    if choosingAnchor { anchor=point;return }
                    if active==nil { showSelection=true;model.cancel();active=RepairStroke(points:[point],diameter:diameter,erase:erasing) }
                    else if let last=active?.points.last,hypot((point.x-last.x)*CGFloat(displayed.width),(point.y-last.y)*CGFloat(displayed.height))>=max(1,diameter/4),active!.points.count<2048 { active?.points.append(point) }
                }.onEnded { _ in
                    if choosingAnchor { choosingAnchor=false;return }
                    if let stroke=active,selection.strokes.count<256 { selection.strokes.append(stroke) };active=nil
                })
        }
    }
    @ViewBuilder private var previewBacking: some View {
        switch previewBackground {
        case .checkerboard: TransparencyGrid()
        case .light: Color.white.accessibilityHidden(true)
        case .dark: Color(white:0.08).accessibilityHidden(true)
        }
    }
    private func importModel() {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=true;panel.allowsMultipleSelection=false
        panel.message=L10n.text("导入你已取得使用权的本地Core ML修复模型。支持图像+mask图像输入、图像输出；不修改原模型。")
        panel.begin { response in if response == .OK,let url=panel.url { model.importModel(url) } }
    }
}
