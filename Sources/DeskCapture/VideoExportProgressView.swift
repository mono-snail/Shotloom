import SwiftUI

struct VideoExportProgressView: View {
    let progress: Double?
    let status: String
    let cancelling: Bool
    let cancel: () -> Void

    private var fraction: Double? {
        guard let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    private var currentStatus: String { cancelling ? L10n.text("正在取消…") : status }

    var body: some View {
        HStack(spacing: 8) {
            if let fraction {
                ProgressView(value: fraction).frame(width: 120).accessibilityLabel(currentStatus)
                Text("\(Int(fraction * 100))%").monospacedDigit().accessibilityHidden(true)
            } else { ProgressView().controlSize(.small).accessibilityLabel(currentStatus) }
            Text(currentStatus).foregroundStyle(Palette.muted).accessibilityHidden(true)
            Spacer(minLength: 8)
            Button(L10n.text("取消处理"), action: cancel).disabled(cancelling)
        }.font(.system(size: 12))
    }
}
