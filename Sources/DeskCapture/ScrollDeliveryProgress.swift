import SwiftUI

/// Presentation follows the actual handoff destination, without changing its
/// cancellation or commit boundary.
enum ScrollDeliveryProgress: CaseIterable {
    case clipboard, editor, file, segments, cancelling

    init(output: ScrollCaptureOutput) {
        switch output {
        case .clipboard: self = .clipboard
        case .editor: self = .editor
        case .file: self = .file
        case .segments: self = .segments
        }
    }

    var title: String {
        switch self {
        case .clipboard: L10n.text("正在生成")
        case .editor: L10n.text("准备编辑器")
        case .file: L10n.text("正在保存")
        case .segments: L10n.text("导出分块")
        case .cancelling: L10n.text("正在取消")
        }
    }

    var message: String {
        switch self {
        case .clipboard: L10n.text("正在生成长图，完成后复制。捕获片段已保留。")
        case .editor: L10n.text("正在准备编辑器，捕获片段保留至交接完成。")
        case .file: L10n.text("正在保存长图，捕获片段已保留。可取消本次导出。")
        case .segments: L10n.text("正在导出原分辨率分块，捕获片段已保留。")
        case .cancelling: L10n.text("正在处理取消请求，请等待当前操作结束。")
        }
    }
}

struct ScrollDeliveryProgressView: View {
    let progress: ScrollDeliveryProgress

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).padding(.top, 2)
                .accessibilityLabel(progress.title)
            Text(progress.message).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
