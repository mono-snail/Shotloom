import AppKit
import SwiftUI

struct ImageDeliveryState {
    var status: String?
    var cancelling = false
    var message: String?
    var error: String?
    var savedURL: URL?
    var busy: Bool { status != nil }
    var hasResult: Bool { status != nil || message != nil || savedURL != nil }
}

enum ImageDeliveryOutcome {
    case saved(URL), copied, cancelled, failed(String)
}

/// Window-local presentation for the coordinator's existing encoders. A token
/// prevents cancelled/closed requests from changing a newer operation's UI.
@MainActor final class ImageDeliveryFeedback: ObservableObject {
    @Published private(set) var state = ImageDeliveryState()
    private var request = UUID()
    private var cancelWork: (() -> Void)?

    func begin(_ status: String, cancel: @escaping () -> Void) -> UUID {
        request = UUID(); cancelWork = cancel
        state.status = status; state.cancelling = false; state.message = nil; state.error = nil
        return request
    }
    func update(_ status: String, token: UUID) {
        guard token == request, !state.cancelling else { return }
        state.status = status
    }
    func complete(_ outcome: ImageDeliveryOutcome, token: UUID, copiedMessage: String = L10n.text("图片已复制")) {
        guard token == request else { return }
        state.status = nil; state.cancelling = false; cancelWork = nil
        switch outcome {
        case .saved(let url): state.savedURL = url; state.message = nil; state.error = nil
        case .copied: state.savedURL = nil; state.message = copiedMessage; state.error = nil
        case .cancelled: state.message = L10n.text("已取消"); state.error = nil
        case .failed(let error): state.message = nil; state.error = error
        }
    }
    func cancel() {
        guard state.busy, !state.cancelling else { return }
        state.cancelling = true; state.status = L10n.text("正在取消…"); cancelWork?()
    }
    func dismissError() { state.error = nil }
    func invalidate() {
        let cancel = cancelWork
        request = UUID(); cancelWork = nil; state = ImageDeliveryState()
        cancel?()
    }
}

struct StudioImageDeliveryStatus: View {
    let state: ImageDeliveryState
    var cancel: () -> Void = {}

    @ViewBuilder var body: some View {
        if let status = state.status {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityLabel(status)
                Text(status).foregroundStyle(Palette.muted).accessibilityHidden(true)
                Button(L10n.text("取消"), action: cancel).disabled(state.cancelling)
            }
        } else if let message = state.message {
            Text(message).foregroundStyle(Palette.muted)
        } else if let url = state.savedURL {
            StudioExportReceipt(url: url)
        }
    }
}
