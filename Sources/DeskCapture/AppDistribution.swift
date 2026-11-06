import Foundation

#if APP_STORE && DIRECT_DISTRIBUTION
#error("APP_STORE and DIRECT_DISTRIBUTION must not be enabled together.")
#endif

/// A build-time choice, never inferred from receipts, preferences, or a server.
/// Capture, editing and project formats are shared by all distributions.
enum AppDistribution {
    enum Channel: String { case appStore = "app-store", direct, development }

    static var channel: Channel {
        #if APP_STORE
        return .appStore
        #elseif DIRECT_DISTRIBUTION
        return .direct
        #else
        return .development
        #endif
    }

    static var usesExternalCommerce: Bool { channel == .direct }

    static var urlScheme: String {
        channel == .direct ? "shotloom-direct" : "deskcapture"
    }
}
