import SwiftUI

struct ScrollHUD: View {
    static let initialSize = CGSize(width: 344, height: 474)
    @ObservedObject var scroll: ScrollCapture
    let finish: () -> Void
    let save: () -> Void
    let cancel: () -> Void
    var edit: (() -> Void)? = nil
    var onAutomaticChange: ((Bool) -> Void)? = nil
    var resize: (CGSize) -> Void = { _ in }
    @State private var followsTail = true
    @State private var overview = false
    @State private var previewCollapsed = false
    @State private var showingContainers = false
    @State private var showingDynamicRegions = false

    private var controlsBusy: Bool { scroll.finishing || scroll.choosingFile || scroll.processingSegment }
    private var manualContinuation: Bool { scroll.automatic && scroll.paused }
    private var notice: String? {
        if let progress = scroll.deliveryProgress { return progress.message }
        if scroll.choosingFile { return L10n.text("正在选择保存位置。取消后将恢复原捕获状态。") }
        return scroll.warning
    }
    private var panelSize: CGSize {
        // Only structural changes resize the panel; frames, progress and text
        // updates never enter this geometry, so polling cannot shake the window.
        CGSize(width: Self.initialSize.width,
               height: 170 + (previewCollapsed ? 0 : 304) + (notice == nil ? 0 : 88)
                   + (manualContinuation ? 40 : 0) + (scroll.suggestedFixedEdges == nil ? 0 : 48))
    }
    private var title: String {
        if scroll.source == .window { return L10n.text("窗口长图 · \(scroll.direction.movementTitle(axis: scroll.axis))") }
        if scroll.direction == .reverse { return L10n.text("\(scroll.direction.movementTitle(axis: scroll.axis))长图") }
        return scroll.axis == .vertical ? L10n.text("长截图") : L10n.text("横向长图")
    }
    private var status: String {
        if let progress = scroll.deliveryProgress { return progress.title }
        if scroll.choosingFile { return L10n.text("选择位置") }
        if scroll.processingSegment { return L10n.text("正在处理") }
        if scroll.paused { return scroll.stopReason?.title ?? (scroll.needsSeamRecovery ? L10n.text("接缝待恢复") : L10n.text("已暂停")) }
        return scroll.waitingForStableFrame ? L10n.text("等待稳定") : L10n.text("捕获中")
    }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 48)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    modeControls.frame(height: 56)
                    if !previewCollapsed { previewControls.frame(height: 304) }
                    if manualContinuation {
                        HStack {
                            Button(L10n.text("选择滚动正文…")) { showingContainers = true }.buttonStyle(StudioButtonStyle(command: true)).controlSize(.small)
                                .disabled(controlsBusy)
                            Button(L10n.text("改为手动继续")) { scroll.continueManually() }.buttonStyle(StudioButtonStyle(command: true)).controlSize(.small)
                                .disabled(controlsBusy)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 16).frame(height: 40)
                    }
                    if let edges = scroll.suggestedFixedEdges {
                        HStack(spacing: 8) {
                            Button(L10n.text("合并固定栏并继续")) { Task { await scroll.configureFixedEdges(edges) } }
                            Button(L10n.text("保留全部并继续")) { Task { await scroll.configureFixedEdges(.none) } }
                            Spacer(minLength: 0)
                        }.controlSize(.small).padding(.horizontal, 16).frame(height: 48).disabled(controlsBusy)
                    }
                    if let notice {
                        ScrollView {
                            if let progress = scroll.deliveryProgress {
                                ScrollDeliveryProgressView(progress: progress)
                            } else {
                                StudioMessage(text: notice, kind: scroll.choosingFile || scroll.stopReason == .boundary ? .information : .warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.frame(height: 72).padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }.scrollBounceBehavior(.basedOnSize)
            Divider()
            deliveryControls.frame(height: 64)
        }
        .frame(width: panelSize.width)
        .frame(minHeight: 170, idealHeight: panelSize.height, maxHeight: .infinity)
        .foregroundStyle(Palette.white).background(OpticalPanel(radius: 16))
        .onAppear { resize(panelSize) }
        .onChange(of: panelSize) { _, size in resize(size) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CaptureDragHandle().frame(width: 10, height: 24)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
                .help(scroll.source == .window ? L10n.text("正在捕获“\(scroll.targetName)”的窗口") : L10n.text("区域滚动长图"))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(scroll.stopReason == .boundary ? Color.green : scroll.paused ? Color.orange : Palette.ice).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(status).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.frame(width: 78, alignment: .trailing).accessibilityElement(children: .combine)
            StudioIconButton(title: previewCollapsed ? L10n.text("展开预览") : L10n.text("收起预览"), symbol: previewCollapsed ? "chevron.down" : "chevron.up") {
                previewCollapsed.toggle()
            }
        }.padding(.horizontal, 16)
    }
    private var modeControls: some View {
        HStack(spacing: 10) {
            #if APP_STORE
            Text(L10n.text("手动滚动拼接"))
            Spacer(minLength: 0)
            #else
            Toggle(L10n.text("自动滚动"), isOn: Binding(get: { scroll.automatic }, set: { value in
                if let onAutomaticChange { onAutomaticChange(value) } else { scroll.setAutomatic(value) }
            })).toggleStyle(.switch).controlSize(.small).fixedSize()
            Spacer(minLength: 0)
            if scroll.needsAutomationPermission {
                Button(L10n.text("授权设置")) { scroll.openAutomationSettings() }.controlSize(.small)
            } else if scroll.automatic {
                Picker(L10n.text("滚动速度"), selection: Binding(get: { scroll.speed }, set: { scroll.setSpeed($0) })) {
                    ForEach(ScrollCaptureSpeed.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 90, alignment: .trailing)
            }
            #endif
            Menu {
                #if !APP_STORE
                Button(L10n.text("选择滚动区域…")) { showingContainers = true }
                #endif
                if !scroll.unstableRegions.isEmpty { Button(L10n.text("查看动态区域…")) { showingDynamicRegions = true } }
                Divider()
                Button(L10n.text("导出分块 PNG 文件夹…")) { ScrollFileDialog.presentSegments(for: scroll) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 32) }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.text("长图选项")).accessibilityLabel(L10n.text("长图选项"))
                .popover(isPresented: $showingContainers) { ScrollContainerPicker(scroll: scroll) }
                .popover(isPresented: $showingDynamicRegions) { ScrollDynamicRegionsView(image: scroll.stabilityThumbnail, regions: scroll.unstableRegions) }
        }.font(.system(size: 12)).padding(.horizontal, 16).disabled(controlsBusy)
    }
    private var previewControls: some View {
        VStack(spacing: 0) {
            ScrollPreviewView(preview: scroll.preview, overview: overview, followsTail: $followsTail)
                .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.separator)).padding(.horizontal, 16)
            HStack(spacing: 8) {
                Text("\(scroll.preview.width) × \(scroll.preview.height) px").monospacedDigit()
                Spacer(minLength: 0)
                if scroll.source == .window {
                    Text(scroll.targetName).lineLimit(1).frame(maxWidth: 80, alignment: .trailing).help(scroll.targetName)
                }
                if !scroll.fixedEdges.isEmpty {
                    Image(systemName: "pin.fill").help(L10n.text("固定栏在结果中只保留一次")).accessibilityLabel(L10n.text("固定栏只保留一次"))
                }
                Text(L10n.text("\(scroll.frames) 段")).monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 16).frame(height: 32)
            HStack(spacing: 8) {
                Toggle(L10n.text("跟随新增"), isOn: $followsTail).toggleStyle(.checkbox).disabled(overview).font(.system(size: 11))
                Spacer(minLength: 0)
                StudioIconButton(title: L10n.text("撤回末段"), symbol: "arrow.uturn.backward") { Task { await scroll.removeLastSegment() } }
                    .disabled(scroll.frames < 2 || controlsBusy)
                StudioIconButton(title: overview ? L10n.text("查看细节") : L10n.text("查看整图"), symbol: overview ? "plus.magnifyingglass" : "arrow.down.right.and.arrow.up.left", selected: overview) {
                    overview.toggle()
                }
            }.padding(.horizontal, 16).frame(height: 40).padding(.bottom, 12)
        }
    }
    private var deliveryControls: some View {
        HStack(spacing: 8) {
            StudioIconButton(title: scroll.paused ? L10n.text("继续捕获") : L10n.text("暂停捕获"), symbol: scroll.paused ? "play.fill" : "pause.fill") { scroll.togglePause() }
                .disabled(controlsBusy)
            StudioIconButton(title: scroll.finishing ? L10n.text("取消完成操作") : L10n.text("取消长截图"), symbol: "xmark", action: cancel)
                .disabled(scroll.cancelExportRequested)
            Spacer(minLength: 0)
            if edit != nil, !scroll.requiresStreamingExport {
                StudioIconButton(title: L10n.text("完成并复制"), symbol: "doc.on.clipboard", action: finish).disabled(controlsBusy)
            }
            Button(scroll.requiresStreamingExport ? L10n.text("保存 PDF…") : L10n.text("保存…"), action: save)
                .buttonStyle(StudioButtonStyle(command: true)).controlSize(.small).disabled(controlsBusy)
            Button { ScrollFileDialog.complete(for: scroll, copy: edit ?? finish) } label: {
                Text(scroll.deliveryProgress.map { $0.title + "…" } ?? (scroll.requiresStreamingExport ? L10n.text("导出分块…") : edit == nil ? L10n.text("复制") : L10n.text("完成并编辑")))
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 32)
            }.buttonStyle(StudioButtonStyle(primary: true, radius: 8)).disabled(controlsBusy)
                .help(scroll.requiresStreamingExport ? L10n.text("导出原分辨率 PNG 分块及位置清单") : edit == nil ? L10n.text("完成长截图并复制") : L10n.text("保留到历史并打开编辑器，可标注、删段和保存"))
        }.padding(.horizontal, 16).disabled(scroll.choosingFile)
    }
}
