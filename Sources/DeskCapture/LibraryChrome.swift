import SwiftUI

/// Library chrome stays still while the collection loads, filters or changes.
struct StudioLibraryHeader<Actions: View>: View {
    let title: String
    let symbol: String
    let count: Int
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                heading.fixedSize()
                Spacer(minLength: 16)
                HStack(spacing: 8) { actions() }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { actions() }.fixedSize(horizontal: true, vertical: false)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .buttonStyle(StudioButtonStyle(command: true))
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var heading: some View {
        HStack(spacing: 10) {
            StudioHeader(title: title, symbol: symbol, compact: true)
            Text(count.formatted()).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(Palette.muted).accessibilityLabel(L10n.text("共\(count)项"))
        }
    }
}

struct StudioLibrarySearch: View {
    let title: String
    @Binding var text: String
    var searching = false
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted).accessibilityHidden(true)
            TextField(title, text: $text).textFieldStyle(.plain).focused($focused).autocorrectionDisabled()
                .accessibilityLabel(title)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""; return .handled
                }
            if searching { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在搜索")) }
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted).frame(width: 28, height: 28)
                }.buttonStyle(StudioButtonStyle(radius: 6, quiet: true))
                    .help(L10n.text("清除搜索")).accessibilityLabel(L10n.text("清除搜索"))
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 12).frame(minHeight: 38)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Palette.ice : (contrast == .increased ? Palette.separator : Palette.chrome.opacity(0.10)),
                                                               lineWidth: focused ? 1.5 : 1))
        .background {
            // A window-local command, without an extra visible or Tab-focusable button.
            Button(L10n.text("搜索素材")) { focused = true }.keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain).focusable(false).frame(width: 0, height: 0).clipped().accessibilityHidden(true)
        }
        .help(L10n.text("搜索素材 ⌘F；Esc 清除。支持短语、标签与排除条件。"))
    }
}

struct StudioLibraryFooter: View {
    let summary: String
    var moreTitle: String? = nil
    var more: () -> Void = {}
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(summary).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.muted)
                    .lineLimit(1).help(summary)
                Spacer(minLength: 8)
                if let moreTitle { Button(moreTitle, action: more).controlSize(.small) }
            }.padding(.horizontal, 20).frame(minHeight: 44).background(Palette.paper)
                .buttonStyle(StudioButtonStyle(command: true))
        }
    }
}

enum StudioMessageKind {
    case information, warning, error
    var symbol: String {
        switch self { case .information: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "exclamationmark.circle" }
    }
    var color: Color {
        switch self { case .information: Palette.ice; case .warning: .orange; case .error: .red }
    }
}

/// Actual progress, errors and results only; not a place for standing instructions.
struct StudioMessage: View {
    let text: String
    var kind: StudioMessageKind = .information
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol).foregroundStyle(kind.color).frame(width: 16, height: 18).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help(L10n.text("关闭提示")).accessibilityLabel(L10n.text("关闭提示"))
            }
        }.font(.system(size: 12)).padding(12)
            .background(kind.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StudioLibraryEmpty<Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(Palette.ice)
                    .frame(width: 56, height: 56).background(Palette.selection, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 16, weight: .medium)).multilineTextAlignment(.center)
                adaptiveActions.controlSize(.regular)
            }.padding(28)
            VStack(spacing: 12) {
                Text(title).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.center)
                adaptiveActions
            }.padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .buttonStyle(StudioButtonStyle(command: true))
    }

    private var adaptiveActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actions() }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 10) { actions() }
        }
    }
}

struct StudioLibraryLoading: View {
    let title: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular).accessibilityLabel(title)
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.muted).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioBatchSelectionBar: View {
    let total: Int
    let selected: Int
    let select: () -> Void
    let clear: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(total > 1000 ? L10n.text("选择前1000项") : L10n.text("全选此范围"), action: select).disabled(total == 0)
            Button(L10n.text("清空选择"), action: clear).disabled(selected == 0)
            Spacer(minLength: 8)
            Text(L10n.text("已选 \(selected) / \(total)")).monospacedDigit().foregroundStyle(Palette.muted)
        }.font(.system(size: 12)).controlSize(.small).frame(minHeight: 32)
            .buttonStyle(StudioButtonStyle(command: true))
    }
}

/// Shared framing for screenshot cards and recording rows; content keeps its own layout.
struct StudioLibraryItemSurface: ViewModifier {
    var hovered = false
    var radius: CGFloat = 12
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Palette.paper, in: shape)
            .overlay(shape.strokeBorder(hovered ? Palette.ice.opacity(0.4) :
                (contrast == .increased ? Palette.separator : Palette.chrome.opacity(0.08))))
    }
}
