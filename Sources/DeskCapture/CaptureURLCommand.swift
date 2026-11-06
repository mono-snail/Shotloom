import Foundation

enum CaptureURLCommand {
    case capture(CaptureMode, delay: Int, repeatSelection: Bool)
    case history, settings
    case workflow(UUID?)
    init?(_ url: URL) {
        // Direct builds register their own scheme so installing a candidate
        // cannot claim the App Store app's workflow links. Explicit legacy
        // links passed to this app remain readable for existing integrations.
        guard let scheme = url.scheme?.lowercased(),
              scheme == AppDistribution.urlScheme || scheme == "deskcapture",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch url.host?.lowercased() {
        case "workflow":
            guard url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { return nil }
            let items = parts.queryItems ?? []
            guard items.count <= 1, items.allSatisfy({ $0.name == "id" }) else { return nil }
            if let item = items.first { guard let raw = item.value, let id = UUID(uuidString: raw) else { return nil }; self = .workflow(id) }
            else { self = .workflow(nil) }
        case "history": self = .history
        case "settings": self = .settings
        case "capture":
            let items = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            guard let mode = CaptureMode(rawValue: items["mode"] ?? "region") else { return nil }
            self = .capture(mode, delay: max(0, min(10, Int(items["delay"] ?? "0") ?? 0)), repeatSelection: items["repeat"] == "1")
        default: return nil
        }
    }
}
