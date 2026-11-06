import SwiftUI

/// Presentation geometry only; keep native window constraints and SwiftUI in agreement.
enum StudioMetrics {
    static let workspaceMinimum = CGSize(width: 820, height: 560)
    static let settingsMinimum = CGSize(width: 760, height: 540)
    static let libraryMinimum = CGSize(width: 600, height: 440)
    static let contentInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let fieldSpacing: CGFloat = 8
    static let videoFieldTitleHeight: CGFloat = 32
    static let controlSpacing: CGFloat = 12
    static let barHeight: CGFloat = 56
    static let iconTarget: CGFloat = 32
    static let controlRadius: CGFloat = 8
    static let groupRadius: CGFloat = 12
    static let inspectorMinimum: CGFloat = 300
    static let inspectorIdeal: CGFloat = 320
    static let inspectorMaximum: CGFloat = 360
}

/// Keep every action reachable when labels or a window's content become wider.
struct StudioActionBar<Actions: View>: View {
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: StudioMetrics.controlSpacing) { actions() }
            ScrollView(.horizontal) {
                HStack(spacing: StudioMetrics.controlSpacing) { actions() }
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, StudioMetrics.contentInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: StudioMetrics.barHeight)
        .font(.system(size: 13))
        .buttonStyle(StudioButtonStyle(command: true))
        .background(Palette.paper)
    }
}
