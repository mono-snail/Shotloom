import SwiftUI

struct WorkflowStepFields: View {
    @Binding var step: LocalWorkflowStep
    var brands: [TutorialPreset] = []
    var chooseBrand: (TutorialPreset) -> Void = { _ in }
    private var watermark: Binding<ImageWatermark> {
        Binding(get: { step.watermark ?? .init(enabled: true) }, set: { step.watermark = $0 })
    }
    private var appearance: Binding<WorkflowAppearance> {
        Binding(get: { step.appearance ?? .init() }, set: { step.appearance = $0; step.presetData = nil })
    }
    @ViewBuilder var body: some View {
        switch step.kind {
        case .watermark:
            WatermarkFields(value: watermark, compact: true)
        case .beautify:
            if !brands.isEmpty {
                StudioMenu(L10n.text("品牌预设")) {
                    ForEach(brands) { preset in Button(preset.name) { chooseBrand(preset) } }
                }
            }
            if step.appearance == nil, step.presetData != nil {
                Label(L10n.text("使用已有品牌预设"), systemImage: "checkmark.circle")
                Button(L10n.text("改用美化参数")) { step.presetData = nil; step.appearance = .init() }
            } else {
                InspectorControlGrid {
                InspectorField(title: L10n.text("背景")) { WorkflowBackgroundPicker(selection: appearance.style) }
                InspectorField(title: L10n.text("比例")) {
                    Picker(L10n.text("比例"), selection: appearance.layout) {
                        ForEach(BeautifyLayout.allCases) { Text($0.title).tag($0) }
                    }
                }
                InspectorSlider(title: L10n.text("留白"), value: appearance.padding, range: 0...0.35, scale: 100, unit: "%")
                InspectorSlider(title: L10n.text("圆角"), value: appearance.roundness, range: 0...1, scale: 100, unit: "%")
                }
            }
        case .resize:
            InspectorField(title: L10n.text("长边上限（像素）")) {
                TextField(L10n.text("长边像素"), value: $step.value, format: .number)
            }
        case .trim:
            InspectorField(title: L10n.text("留白识别容差")) {
                HStack {
                    Stepper(value: $step.value, in: 0...64) { Text("\(step.value)").monospacedDigit() }
                }
            }
        case .rotate:
            InspectorField(title: L10n.text("顺时针旋转")) {
                Picker(L10n.text("顺时针旋转"), selection: $step.value) {
                    Text("90°").tag(1); Text("180°").tag(2); Text("270°").tag(3)
                }.pickerStyle(.segmented)
            }
        case .mirror:
            InspectorField(title: L10n.text("翻转方向")) {
                Picker(L10n.text("翻转方向"), selection: $step.value) {
                    Text(L10n.text("水平")).tag(1); Text(L10n.text("垂直")).tag(2)
                }.pickerStyle(.segmented)
            }
        case .sensitiveReview:
            Label(L10n.text("运行时确认遮盖区域"), systemImage: "person.crop.rectangle.badge.checkmark")
        case .ocr:
            Label(L10n.text("识别处理后的图片"), systemImage: "text.viewfinder")
        }
    }
}

struct WorkflowOutputFields: View {
    @Binding var value: WorkflowOutput
    let hasText: Bool
    let chooseFolder: () -> Void
    var body: some View {
        InspectorControlGrid {
            InspectorField(title: L10n.text("完成后")) {
                Picker(L10n.text("完成后"), selection: $value.kind) {
                    ForEach(WorkflowOutput.Kind.allCases.filter { hasText || ![.copyText, .saveText].contains($0) || $0 == value.kind }) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
            }
            if value.kind == .saveImage {
                InspectorField(title: L10n.text("格式")) {
                    Picker(L10n.text("格式"), selection: $value.format) {
                        ForEach(WorkflowOutput.Format.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            if value.writesFile {
                InspectorField(title: L10n.text("保存到")) {
                    Menu {
                        Button(L10n.text("选择固定目录…"), action: chooseFolder)
                        Button(L10n.text("每次选择位置")) { value.directoryBookmark = nil; value.directoryName = nil }
                    } label: {
                        Text(value.directoryName ?? L10n.text("每次选择")).lineLimit(1).truncationMode(.middle)
                    }.help(value.directoryName ?? L10n.text("运行时选择保存位置"))
                }
                InspectorField(title: L10n.text("文件名前缀")) {
                    TextField(L10n.text("文件名前缀"), text: $value.prefix)
                        .onChange(of: value.prefix) { _, text in if text.count > 40 { value.prefix = String(text.prefix(40)) } }
                }
            }
        }
    }
}

struct WorkflowToolbarSettings: View {
    @ObservedObject private var catalog = WorkflowCatalog.shared
    @State private var updating = false
    @State private var error: String?
    let open: (UUID?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(title: L10n.text("自定义流程")) { Button(L10n.text("管理流程…")) { open(nil) } }
            ForEach(catalog.recipes) { recipe in
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { recipe.inCaptureToolbar == true }, set: { enabled in
                        var snapshot = recipe; snapshot.inCaptureToolbar = enabled; snapshot.version = 2
                        updating = true
                        Task { @MainActor in
                            defer { updating = false }
                            do { try await LocalWorkflowLibrary.shared.save(snapshot); await catalog.refresh(); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    })) { Label(recipe.name, systemImage: recipe.toolbarSymbol) }.toggleStyle(InspectorToggleStyle())
                    StudioIconButton(title: L10n.text("编辑\(recipe.name)"), symbol: "pencil") { open(recipe.id) }
                }.frame(minHeight: 40)
            }
            if let message = error ?? catalog.error { Text(message).foregroundStyle(.orange) }
        }.disabled(updating).task { await catalog.refresh() }
    }
}

/// Structural editing stays visible even when a tool's parameter body is closed.
struct WorkflowStepHeader: View {
    let step: LocalWorkflowStep
    let number: Int
    @Binding var expanded: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let unavailable: [LocalWorkflowStep.Kind]
    let replace: (LocalWorkflowStep.Kind) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("\(number)").monospacedDigit().foregroundStyle(Palette.muted).frame(width: 16)
                .draggable(step.id.uuidString).help(L10n.text("拖动第\(number)步以排序"))
            Picker(L10n.text("第\(number)步工具"), selection: Binding(get: { step.kind }, set: replace)) {
                ForEach(LocalWorkflowStep.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                        .disabled((kind == .ocr || kind == .sensitiveReview) && unavailable.contains(kind))
                }
            }.labelsHidden().frame(minWidth: 76, maxWidth: .infinity, alignment: .leading)
                .help(L10n.text("更换第\(number)步工具：\(step.kind.title)"))
            StudioIconButton(title: expanded ? L10n.text("收起参数") : L10n.text("展开参数"), symbol: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
            StudioIconButton(title: L10n.text("上移第\(number)步"), symbol: "arrow.up", action: moveUp).disabled(!canMoveUp)
            StudioIconButton(title: L10n.text("下移第\(number)步"), symbol: "arrow.down", action: moveDown).disabled(!canMoveDown)
            StudioIconButton(title: L10n.text("删除第\(number)步"), symbol: "trash", action: remove)
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text("第\(number)步"))
    }
}

/// Keep a visual background choice without permanently spending two inspector
/// rows on a palette. The existing shared swatches open at their normal width.
private struct WorkflowBackgroundPicker: View {
    @Binding var selection: BeautifyStyle
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: selection.colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 20, height: 20)
                Text(selection.title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, minHeight: 26)
        }.buttonStyle(StudioButtonStyle(quiet: true, accentHover: true))
            .accessibilityLabel(L10n.text("背景：\(selection.title)"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                BackgroundSwatches(selection: Binding(get: { selection }, set: { selection = $0; showing = false }))
                    .frame(width: 252).padding(14).background(Palette.paper)
            }
    }
}
