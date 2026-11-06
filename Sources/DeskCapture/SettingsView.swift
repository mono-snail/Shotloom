import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var app: AppCoordinator
    var close: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var usage = LocalUsage.shared
    @AppStorage("localUsageEnabled", store: AppPreferences.standard) private var localUsageEnabled = false
    @AppStorage("hideDesktop", store: AppPreferences.standard) private var hideDesktop = false
    @AppStorage("windowBackdrop", store: AppPreferences.standard) private var windowBackdrop = WindowBackdrop.transparent.rawValue
    @AppStorage("windowShadow", store: AppPreferences.standard) private var windowShadow = false
    @AppStorage("clipboardLogicalSize", store: AppPreferences.standard) private var clipboardLogicalSize = false
    @AppStorage("saveAlsoCopies", store: AppPreferences.standard) private var saveAlsoCopies = false
    @AppStorage("autoOCRIndex", store: AppPreferences.standard) private var autoOCRIndex = true
    @AppStorage("appearanceMode", store: AppPreferences.standard) private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.preferenceKey, store: AppPreferences.standard) private var appLanguage = AppLanguage.english.rawValue
    @State private var showsLanguageNotice = false
    @State private var section = SettingsSection.general
    @FocusState private var focusedSection: SettingsSection?
    private let remembersSelection: Bool
    init(app: AppCoordinator, close: @escaping () -> Void = {}, initialSection: SettingsSection? = nil) {
        self.app = app; self.close = close; remembersSelection = initialSection == nil
        let saved = AppPreferences.standard.string(forKey: "settings.lastSection").flatMap(SettingsSection.init(rawValue:))
        _section = State(initialValue: initialSection ?? saved ?? .general)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                StudioHeader(title: AppIdentity.name, symbol: "viewfinder", compact: true)
                    .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(SettingsSection.allCases) { item in
                            Button { section = item } label: {
                                Label {
                                    Text(L10n.translate(item.rawValue)).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                                } icon: {
                                    Image(systemName: item.symbol).font(.system(size: 15, weight: .medium))
                                        .frame(width: 22).accessibilityHidden(true)
                                }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).padding(.horizontal, 10)
                            }
                            .buttonStyle(StudioNavigationStyle(selected: section == item))
                            .focused($focusedSection, equals: item).focusEffectDisabled()
                            .accessibilityAddTraits(section == item ? .isSelected : [])
                            .accessibilityIdentifier("settings-\(item.id)")
                            .onKeyPress(.upArrow) { moveSection(from: item, offset: -1); return .handled }
                            .onKeyPress(.downArrow) { moveSection(from: item, offset: 1); return .handled }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                }.accessibilityLabel(L10n.text("设置分类"))
                Text(L10n.text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("开发版"))"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(18)
            }.frame(width: 200).background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.translate(section.rawValue)).font(.system(size: 20, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    StudioIconButton(title: L10n.text("关闭设置"), symbol: "xmark") { close(); dismiss() }.keyboardShortcut(.cancelAction)
                }.frame(maxWidth: 620)
                    .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch section {
                        case .general: generalSettings
                        case .shortcuts: shortcutSettings
                        case .toolbar: toolbarSettings
                        case .recording: recordingSettings
                        case .storage: storageSettings
                        }
                        if let notice = app.notice { NoticeView(text: notice) }
                    }.frame(maxWidth: 620, alignment: .leading)
                        .padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .center)
                }.id(section).scrollBounceBehavior(.basedOnSize)
            }.foregroundStyle(Palette.white).background(Palette.ink)
        }.frame(minWidth: StudioMetrics.settingsMinimum.width, minHeight: StudioMetrics.settingsMinimum.height).font(.system(size: 13))
            .toggleStyle(.switch).controlSize(.small).tint(Palette.ice)
            .buttonStyle(StudioButtonStyle(command: true))
            .onChange(of: section) { _, value in
                if remembersSelection { AppPreferences.standard.set(value.rawValue, forKey: "settings.lastSection") }
            }
            .alert(L10n.translate("Language saved"), isPresented: $showsLanguageNotice) {
                Button(L10n.translate("OK"), role: .cancel) {}
            } message: {
                Text(L10n.translate("The new language will apply the next time you open the app."))
            }
    }
    private func moveSection(from item: SettingsSection, offset: Int) {
        let items = SettingsSection.allCases
        guard let index = items.firstIndex(of: item) else { return }
        let next = items[min(max(0, index + offset), items.count - 1)]
        section = next; focusedSection = next
    }
    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L10n.text("外观"), symbol: "paintpalette") {
                SettingsRow(title: L10n.translate("App Language")) {
                    Picker(L10n.translate("App Language"), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 220, alignment: .trailing)
                        .accessibilityIdentifier("settings.appLanguage")
                        .onChange(of: appLanguage) { _, value in
                            showsLanguageNotice = value != L10n.language
                        }
                }
                SettingsRow(title: L10n.text("主题")) {
                    Picker(L10n.text("主题"), selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220, alignment: .trailing)
                        .onChange(of: appearanceMode) { _, value in AppAppearance.apply(value) }
                }
            }
            SettingsGroup(title: L10n.text("截图"), symbol: "viewfinder") {
                SettingsToggle(title: L10n.text("隐藏桌面内容"), isOn: $hideDesktop)
                Divider()
                SettingsRow(title: L10n.text("窗口背景")) {
                    Picker(L10n.text("窗口背景"), selection: $windowBackdrop) {
                        ForEach(WindowBackdrop.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 180, alignment: .trailing)
                }
                SettingsToggle(title: L10n.text("窗口阴影"), isOn: $windowShadow)
            }
            SettingsGroup(title: L10n.text("复制与历史"), symbol: "doc.on.clipboard") {
                SettingsToggle(title: L10n.text("粘贴时匹配屏幕尺寸"), isOn: $clipboardLogicalSize)
                SettingsToggle(title: L10n.text("保存后复制图片"), isOn: $saveAlsoCopies)
                SettingsToggle(title: L10n.text("识别历史文字"), isOn: $autoOCRIndex)
            }
            SettingsGroup(title: L10n.text("更新"), symbol: "arrow.triangle.2.circlepath") {
                AppUpdateSettingsView(updates: app.updates)
            }
            SettingsGroup(title: L10n.translate("Support and Feedback"), symbol: "bubble.left.and.bubble.right") {
                SettingsRow(title: L10n.text("支持与帮助")) {
                    Button(L10n.translate("Support and Feedback…")) { ShotloomSupportWindow.shared.show() }
                        .buttonStyle(StudioButtonStyle(command: true))
                }
                SettingsRow(title: L10n.translate("Privacy Policy")) {
                    Button(L10n.translate("Open Privacy Policy")) { NSWorkspace.shared.open(AppSupport.privacyURL) }
                        .buttonStyle(StudioButtonStyle(command: true))
                }
            }
            SettingsGroup(title: L10n.text("屏幕捕获权限"), symbol: "lock.shield") {
                SettingsRow(title: app.permission ? L10n.text("屏幕捕获可用") : L10n.text("尚未确认权限")) {
                    HStack(spacing: 8) {
                        Button(L10n.text("打开系统设置")) { app.openPermissionSettings() }.buttonStyle(StudioButtonStyle(command: true))
                        StudioIconButton(title: L10n.text("重新检查权限"), symbol: "arrow.clockwise") { app.permissionWasDenied?() }
                    }
                }
            }
        }
    }
    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L10n.text("全局热键"), symbol: "keyboard") {
                SettingsRow(title: L10n.text("区域截图")) {
                    ShortcutRecorder(label: app.shortcutLabel, onBinding: app.setCustomShortcut,
                                     onClear: app.clearPrimaryShortcut, canClear: app.primaryShortcutEnabled).frame(width: 230, height: 30)
                }
                SettingsRow(title: L10n.text("区域截图预设")) {
                    StudioMenu(L10n.text("选择预设")) {
                        ForEach(HotKeyPreset.allCases) { preset in
                            Button(preset.label) { app.setShortcut(preset) }
                        }
                    }.frame(width: 150, alignment: .trailing)
                }
                Divider()
                ForEach(CaptureMode.allCases.filter { $0 != .region }) { mode in
                    SettingsRow(title: mode.title) {
                        ShortcutRecorder(label: app.modeBindings[mode.rawValue]?.label ?? L10n.text("录入快捷键"),
                                         onBinding: { app.setModeShortcut(mode, binding: $0) },
                                         onClear: { app.setModeShortcut(mode, binding: nil) },
                                         canClear: app.modeBindings[mode.rawValue] != nil).frame(width: 230, height: 30)
                    }
                }
            }
            SettingsGroup(title: L10n.text("内置快捷键"), symbol: "command") {
                BuiltInShortcutView().padding(.vertical, 8)
            }
        }
    }
    private var toolbarSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L10n.text("显示与排序"), symbol: "square.grid.2x2") {
                ToolbarConfigurationView()
            }
            SettingsGroup(title: L10n.text("截图流程"), symbol: "point.3.connected.trianglepath.dotted") {
                WorkflowToolbarSettings(open: { app.showWorkflow(id: $0) })
            }
        }
    }
    private var recordingSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecordingConfigurationView(recorder: app.recorder, grouped: true)
            #if !APP_STORE
            SettingsGroup(title: L10n.text("长截图"), symbol: "scroll") {
                SettingsToggle(title: L10n.text("默认自动滚动"), isOn: $app.automaticScrolling)
                    .onChange(of: app.automaticScrolling) { _, value in AppPreferences.standard.set(value, forKey: "automaticScrolling") }
            }
            #endif
        }
    }
    private var storageSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup(title: L10n.text("本地历史"), symbol: "externaldrive") {
                SettingsRow(title: L10n.text("自动清理")) {
                    Picker(L10n.text("自动清理"), selection: Binding(get: { app.store.retentionDays }, set: { days in
                        Task {
                            do { try await app.store.setRetentionDaysAsync(days) }
                            catch { app.notice = L10n.text("历史清理失败：\(error.localizedDescription)") }
                        }
                    })) {
                        Text(L10n.text("永不")).tag(0); Text(L10n.text("7 天后")).tag(7); Text(L10n.text("30 天后")).tag(30); Text(L10n.text("90 天后")).tag(90)
                    }.labelsHidden().frame(width: 180, alignment: .trailing)
                }
                Divider()
                SettingsRow(title: L10n.text("历史文件")) {
                    Button(L10n.text("打开文件夹")) {
                        try? FileManager.default.createDirectory(at: app.store.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(app.store.directory)
                    }.buttonStyle(StudioButtonStyle(command: true))
                }
            }
            SettingsGroup(title: L10n.text("本机使用统计"), symbol: "chart.bar") {
                SettingsToggle(title: L10n.text("记录功能使用次数"), isOn: $localUsageEnabled)
                if !usage.counts.isEmpty {
                    Divider()
                    DisclosureGroup(L10n.text("查看使用次数")) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(usage.counts.keys.sorted { (usage.counts[$0] ?? 0) > (usage.counts[$1] ?? 0) }, id: \.self) { key in
                                SettingsRow(title: LocalUsage.titles[key] ?? key) {
                                    Text(L10n.text("\(usage.counts[key] ?? 0) 次")).monospacedDigit().foregroundStyle(Palette.muted)
                                }
                            }
                            SettingsRow(title: L10n.text("重置统计")) {
                                Button(L10n.text("清空计数")) { usage.clear() }.buttonStyle(StudioButtonStyle(command: true))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 10)
                }
            }
        }
    }
}
