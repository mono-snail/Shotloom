import AppKit
import SwiftUI

enum StatusMenuAction: Hashable {
    case capture(CaptureMode), upwardScroll, repeatRegion, delayedCapture(Int), recordWindow
    case dashboard, history, clipboard, beautify, workflow, recordings, video, devices, unlockPins, settings, support, updates, quit
    case stopRecording, pauseRecording, copyScrolling, saveScrolling, cancelScrolling
}

private enum StatusMenuFocus: Hashable {
    case capture(CaptureMode), history
}

/// Snapshot of availability, shared by the visual menu and its dispatch guard.
struct StatusMenuState {
    var recording: RecordingState = .idle
    var scrolling = false
    var scrollingBusy = false
    var capturing = false
    var canRepeat = false
    var screenCount = 1
    var elapsed: TimeInterval = 0
    var captureBusy: Bool { capturing || recording != .idle || scrolling || scrollingBusy }
    func allows(_ action: StatusMenuAction) -> Bool {
        switch action {
        case .capture(let mode): return !captureBusy && mode.isAvailable(screenCount: screenCount)
        case .recordWindow, .delayedCapture, .upwardScroll: return !captureBusy
        case .repeatRegion: return !captureBusy && canRepeat
        case .stopRecording, .pauseRecording: return recording == .recording || recording == .paused
        case .copyScrolling, .saveScrolling: return scrolling && !scrollingBusy
        case .cancelScrolling: return scrolling
        default: return true
        }
    }
    @MainActor init(app: AppCoordinator) {
        recording = app.recorder.state; elapsed = app.recorder.elapsed
        scrolling = app.scrollCapture.active || app.scrollCapture.finishing
        scrollingBusy = app.scrollCapture.finishing || app.scrollCapture.choosingFile || app.scrollCapture.processingSegment
        capturing = app.captureIsBusy; canRepeat = app.lastSelection != nil || app.lastDesktopRegion != nil
        screenCount = app.screenCount
    }
    init(recording: RecordingState = .idle, scrolling: Bool = false, scrollingBusy: Bool = false,
         capturing: Bool = false, canRepeat: Bool = false, screenCount: Int = 1, elapsed: TimeInterval = 0) {
        self.recording = recording; self.scrolling = scrolling; self.scrollingBusy = scrollingBusy
        self.capturing = capturing; self.canRepeat = canRepeat; self.screenCount = screenCount; self.elapsed = elapsed
    }
}

@MainActor
final class StatusMenuController: NSObject {
    let popover = NSPopover()
    private let app: AppCoordinator
    private let perform: (StatusMenuAction) -> Void
    init(app: AppCoordinator, perform: @escaping (StatusMenuAction) -> Void) {
        self.app = app; self.perform = perform
        super.init()
        popover.behavior = .transient
        let host = NSHostingController(rootView: StatusMenuView(app: app,
            perform: { [weak self] in self?.dispatch($0) }, close: { [weak self] in self?.close() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }
    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown { close(); return }
        app.refreshScreenAvailability()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let view = popover.contentViewController?.view, let window = view.window {
            window.makeKey()
            window.makeFirstResponder(view)
        }
    }
    func close() { popover.performClose(nil) }
    func dispatch(_ action: StatusMenuAction) {
        // Close before an action opens a window, picker or frozen-screen overlay.
        guard StatusMenuState(app: app).allows(action) else { return }
        close()
        perform(action)
    }
}

struct StatusMenuView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var scrolling: ScrollCapture
    @ObservedObject private var deviceRecorder: DeviceRecorder
    var previewState: StatusMenuState?
    let perform: (StatusMenuAction) -> Void
    let close: () -> Void
    @State private var hovered: CaptureMode?
    @FocusState private var focused: StatusMenuFocus?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private let modes: [CaptureMode] = [.region, .window, .fullscreen, .text, .scrolling, .recording]
    private var state: StatusMenuState { previewState ?? StatusMenuState(app: app) }
    init(app: AppCoordinator, previewState: StatusMenuState? = nil,
         perform: @escaping (StatusMenuAction) -> Void, close: @escaping () -> Void) {
        self.app = app; recorder = app.recorder; scrolling = app.scrollCapture
        deviceRecorder = app.deviceRecorder
        self.previewState = previewState; self.perform = perform; self.close = close
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top) {
                StudioHeader(title: L10n.text("捕获此刻"), compact: false)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 26, height: 26) }
                    .buttonStyle(StudioButtonStyle(radius: 8, quiet: true)).help(L10n.text("关闭菜单"))
                    .accessibilityLabel(L10n.text("关闭菜单")).keyboardShortcut(.cancelAction)
            }.padding(.bottom, 5)
            if state.recording != .idle { recordingControls }
            if state.scrolling { scrollingControls }
            if state.captureBusy, state.recording == .idle, !state.scrolling {
                StudioMessage(text: app.deviceRecorder.state != .idle ? L10n.text("设备录制进行中") : L10n.text("捕获进行中"))
            }
            regionEntry
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(modes.filter { $0 != .region && $0 != .recording }) { mode in tile(mode) }
                tile(.recording)
                Button { perform(.history) } label: {
                    VStack(spacing: 8) {
                        CaptureGlyph(kind: .collection, size: 32, active: focused == .history)
                        Text(L10n.text("捕获历史")).font(.system(size: 12, weight: .medium))
                    }.frame(maxWidth: .infinity).frame(height: 80)
                }.buttonStyle(StudioButtonStyle(radius: 13)).accessibilityLabel(L10n.text("捕获历史"))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(focused == .history ? Palette.ice : .clear))
                    .focusable().focusEffectDisabled().focused($focused, equals: .history)
                    .onKeyPress(.return) { perform(.history); return .handled }
            }
            HStack(spacing: 6) {
                Button { perform(.repeatRegion) } label: { Label(L10n.text("重复选区"), systemImage: "arrow.counterclockwise").padding(.horizontal, 9).frame(height: 29) }
                    .buttonStyle(StudioButtonStyle(radius: 7, quiet: true)).disabled(!state.allows(.repeatRegion))
                Spacer(minLength: 0)
                Menu {
                    ForEach([3, 5, 10], id: \.self) { seconds in
                        Button(L10n.text("\(seconds) 秒后截图")) { perform(.delayedCapture(seconds)) }.disabled(!state.allows(.delayedCapture(seconds)))
                    }
                } label: { Label(L10n.text("定时"), systemImage: "timer").padding(.horizontal, 6).frame(height: 29) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(state.captureBusy)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            Divider().opacity(0.55)
            VStack(spacing: 2) {
                utility(L10n.text("窗口滚动长图"), symbol: "macwindow", action: .capture(.scrollingWindow), shortcut: app.modeBindings[CaptureMode.scrollingWindow.rawValue]?.label)
                    .disabled(state.captureBusy)
                utility(L10n.text("编辑剪贴板"), symbol: "clipboard", action: .clipboard, shortcut: "⇧⌘V")
                utility(L10n.text("图片美化"), symbol: "sparkles", action: .beautify, shortcut: "⇧⌘B")
                utility(L10n.text("流程"), symbol: "point.3.connected.trianglepath.dotted", action: .workflow, shortcut: nil)
                utility(L10n.text("录屏库"), symbol: "film.stack", action: .recordings, shortcut: nil)
                utility(L10n.text("编辑视频"), symbol: "scissors", action: .video, shortcut: nil)
            }
            Divider().opacity(0.55)
            HStack(spacing: 5) {
                Menu {
                    Button { perform(.dashboard) } label: { Label(L10n.text("浮动快捷面板"), systemImage: "rectangle.grid.1x2") }
                    if state.screenCount > 1 {
                        Button { perform(.capture(.allScreens)) } label: { Label(L10n.text("所有屏幕截图"), systemImage: "display.2") }.disabled(state.captureBusy)
                    }
                    Button { perform(.upwardScroll) } label: { Label(L10n.text("向上长截图"), systemImage: "arrow.up.to.line") }.disabled(state.captureBusy)
                    Button { perform(.recordWindow) } label: { Label(L10n.text("窗口录屏"), systemImage: "macwindow") }.disabled(state.captureBusy)
                    Button { perform(.devices) } label: { Label(L10n.text("设备录制"), systemImage: "iphone") }
                    Button { perform(.updates) } label: { Label(L10n.text("检查更新…"), systemImage: "arrow.triangle.2.circlepath") }
                    Divider()
                    Button { perform(.unlockPins) } label: { Label(L10n.text("解锁所有钉图"), systemImage: "pin.slash") }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L10n.text("更多操作")).accessibilityLabel(L10n.text("更多操作"))
                Spacer(minLength: 0)
                Button { perform(.support) } label: {
                    Label(L10n.translate("Support and Feedback"), systemImage: "bubble.left.and.bubble.right").frame(height: 28)
                }.accessibilityIdentifier("menu.support")
                Button { perform(.settings) } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                    .help(L10n.text("设置")).accessibilityLabel(L10n.text("设置"))
                Button { perform(.quit) } label: { Image(systemName: "power").frame(width: 28, height: 28) }
                    .help(L10n.text("退出 \(AppIdentity.name)")).accessibilityLabel(L10n.text("退出 \(AppIdentity.name)"))
            }.buttonStyle(StudioButtonStyle(radius: 7, quiet: true)).font(.system(size: 11)).foregroundStyle(Palette.muted)
        // NSPopover owns the outer rounding; fill its content without a second rounded edge.
        }.padding(20).frame(width: 374).background(OpticalPanel(radius: 0))
            .foregroundStyle(Palette.white)
            .defaultFocus($focused, state.captureBusy ? .history : .capture(.region))
            .onChange(of: state.captureBusy) { _, busy in if busy, focused != nil { focused = .history } }
            .onKeyPress(.leftArrow) { guard focused != nil else { return .ignored }; moveFocus(by: -1); return .handled }
            .onKeyPress(.rightArrow) { guard focused != nil else { return .ignored }; moveFocus(by: 1); return .handled }
            .onKeyPress(.upArrow) { guard focused != nil else { return .ignored }; moveFocus(by: -3); return .handled }
            .onKeyPress(.downArrow) { guard focused != nil else { return .ignored }; moveFocus(by: 3); return .handled }
    }
    private var regionEntry: some View {
        Button { perform(.capture(.region)) } label: {
            HStack(spacing: 14) {
                CaptureEntryArtwork(active: hovered == .region || focused == .capture(.region))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("区域截图")).font(.system(size: 18, weight: .semibold))
                    Text(app.shortcutLabel).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Palette.onAccent.opacity(0.13), in: Capsule())
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 96)
        }.buttonStyle(StudioButtonStyle(primary: true, radius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(Palette.onAccent.opacity(focused == .capture(.region) ? 0.7 : 0), lineWidth: 2).padding(4).allowsHitTesting(false))
            .focusable().focusEffectDisabled().focused($focused, equals: .capture(.region))
            .onHover { hovered = $0 ? .region : nil }
            .disabled(!state.allows(.capture(.region))).accessibilityLabel(L10n.text("区域截图"))
            .onKeyPress(.return) {
                guard state.allows(.capture(.region)) else { return .ignored }
                perform(.capture(.region)); return .handled
            }
    }
    private func tile(_ mode: CaptureMode) -> some View {
        let active = hovered == mode || focused == .capture(mode)
        let tint = mode == .recording ? OpticalPalette.coral : Palette.ice
        return Button { perform(.capture(mode)) } label: {
            VStack(spacing: 8) {
                tileArtwork(mode, tint: tint, active: active && !state.captureBusy)
                Text(title(mode)).font(.system(size: 13, weight: .medium))
            }.frame(maxWidth: .infinity).frame(height: 80)
                .overlay(alignment: .topTrailing) {
                    if mode == .region {
                        Circle().fill(tint).frame(width: 4, height: 4).padding(9).accessibilityHidden(true)
                    }
                }
        }.buttonStyle(StudioButtonStyle(radius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(focused == .capture(mode) ? 0.8 : mode == .region ? 0.28 : 0), lineWidth: 1).allowsHitTesting(false))
            .focusable().focusEffectDisabled()
            .focused($focused, equals: .capture(mode))
            .disabled(!state.allows(.capture(mode)))
            .onHover { hovered = $0 ? mode : nil }
            .help(mode == .region ? L10n.text("区域截图 \(app.shortcutLabel)") : mode.detail).accessibilityLabel(mode.title)
            .onKeyPress(.return) {
                guard state.allows(.capture(mode)) else { return .ignored }
                perform(.capture(mode)); return .handled
            }
    }
    private func moveFocus(by delta: Int) {
        let entries: [StatusMenuFocus] = [.capture(.region), .capture(.window), .capture(.fullscreen),
                                        .capture(.text), .capture(.scrolling), .capture(.recording), .history]
        guard let focused, let index = entries.firstIndex(of: focused) else { return }
        var target: Int
        if delta == 3 { target = index == 0 ? 1 : min(index + 3, entries.count - 1) }
        else if delta == -3 { target = index <= 3 ? 0 : index - 3 }
        else { target = min(max(index + delta, 0), entries.count - 1) }
        while entries.indices.contains(target) {
            let entry = entries[target]
            if case .capture(let mode) = entry, !state.allows(.capture(mode)) { target += delta < 0 ? -1 : 1 }
            else { self.focused = entry; return }
        }
    }
    @ViewBuilder private func tileArtwork(_ mode: CaptureMode, tint: Color, active: Bool) -> some View {
        switch mode {
        case .region: CaptureGlyph(kind: .region, tint: tint, size: 32, active: active).frame(width: 37, height: 37)
        case .text: CaptureGlyph(kind: .text, tint: tint, size: 32, active: active).frame(width: 37, height: 37)
        case .scrolling: CaptureGlyph(kind: .scrolling, tint: tint, size: 32, active: active).frame(width: 37, height: 37)
        case .recording: CaptureGlyph(kind: .recording, tint: tint, size: 32, active: active).frame(width: 37, height: 37)
        default:
            Image(systemName: mode.symbol).font(.system(size: 24, weight: .light)).foregroundStyle(tint)
                .frame(width: 37, height: 37)
                .scaleEffect(active && !reducedMotion ? 1.08 : 1)
                .animation(reducedMotion ? nil : .easeOut(duration: 0.2), value: active)
                .accessibilityHidden(true)
        }
    }
    private func title(_ mode: CaptureMode) -> String {
        switch mode { case .fullscreen: L10n.text("当前屏幕"); case .scrolling: L10n.text("区域长图"); default: mode.title }
    }
    private func utility(_ title: String, symbol: String, action: StatusMenuAction, shortcut: String?) -> some View {
        Button { perform(action) } label: {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(Palette.ice).frame(width: 22)
                Text(title).font(.system(size: 13))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                else { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Palette.muted) }
            }.padding(.horizontal, 9).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(StudioButtonStyle(radius: 7, quiet: true))
    }
    private var recordingControls: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: state.recording == .paused ? "pause.circle.fill" : "record.circle").foregroundStyle(OpticalPalette.coral)
                Text(state.recording == .preparing ? L10n.text("正在准备录屏") : state.recording == .finishing ? L10n.text("正在保存录屏") : state.recording == .paused ? L10n.text("录屏已暂停") : L10n.text("正在录屏"))
                Spacer()
                Text(String(format: "%02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60)).monospacedDigit()
            }.font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                sessionButton(state.recording == .paused ? L10n.text("继续") : L10n.text("暂停"), symbol: state.recording == .paused ? "play.fill" : "pause.fill", action: .pauseRecording)
                sessionButton(L10n.text("结束并保存"), symbol: "stop.fill", action: .stopRecording)
            }
        }.padding(11).background(OpticalPalette.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var scrollingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.scrollingBusy ? L10n.text("正在处理长截图") : L10n.text("长截图进行中"), systemImage: "arrow.down.to.line.compact")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ice)
            HStack(spacing: 8) {
                sessionButton(L10n.text("完成并复制"), symbol: "doc.on.doc", action: .copyScrolling)
                sessionButton(L10n.text("保存文件"), symbol: "square.and.arrow.down", action: .saveScrolling)
            }
            sessionButton(L10n.text("取消长截图"), symbol: "xmark", action: .cancelScrolling)
        }.padding(11).background(Palette.ice.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func sessionButton(_ title: String, symbol: String, action: StatusMenuAction) -> some View {
        Button { perform(action) } label: {
            Label(title, systemImage: symbol).font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 30)
        }.buttonStyle(StudioButtonStyle(radius: 8)).disabled(!state.allows(action))
    }
}
