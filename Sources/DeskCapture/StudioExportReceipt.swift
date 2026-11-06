import AppKit
import SwiftUI

/// Only shown for an output that the caller has successfully committed.
/// Keep the original media commands separate from this delivered-file action.
struct StudioExportReceipt: View {
    let url: URL
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(Palette.ice).accessibilityHidden(true)
            Text(L10n.text("上次导出")).foregroundStyle(Palette.muted)
            Button { reveal(url) } label: {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
            }.buttonStyle(StudioButtonStyle(command: true))
                .help(L10n.text("在 Finder 中显示：\(url.path)"))
                .accessibilityLabel(L10n.text("在 Finder 中显示上次导出的\(url.lastPathComponent)"))
        }.font(.system(size: 12)).accessibilityElement(children: .contain)
    }
}
