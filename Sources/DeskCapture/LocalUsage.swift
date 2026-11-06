import Foundation
import Combine

@MainActor final class LocalUsage: ObservableObject {
    static let shared = LocalUsage()
    static let titles: [String: String] = ["capture.region": L10n.text("区域截图"), "capture.window": L10n.text("窗口截图"), "capture.fullscreen": L10n.text("当前屏幕截图"), "capture.allScreens": L10n.text("所有屏幕截图"),
        "capture.scrolling": L10n.text("滚动长图"), "capture.recording": L10n.text("录屏"), "capture.text": L10n.text("OCR 捕获"),
        "output.clipboard": L10n.text("复制图片"), "output.file": L10n.text("保存文件"), "output.pin": L10n.text("钉图"),
        "content.ocr": L10n.text("主动识别文字"), "content.sensitive": L10n.text("敏感信息遮盖"), "content.rewrite": L10n.text("原文字改写"),
        "annotation": L10n.text("添加标注"), "overlay": L10n.text("图片叠层")]
    @Published private(set) var counts: [String: Int]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppPreferences.standard) {
        self.defaults = defaults
        counts = (defaults.dictionary(forKey: "localUsageCounts") as? [String: Int] ?? [:])
            .filter { Self.titles[$0.key] != nil && $0.value >= 0 }
    }
    var enabled: Bool { defaults.bool(forKey: "localUsageEnabled") }
    func record(_ key: String) {
        guard enabled, Self.titles[key] != nil else { return }
        counts[key] = min(1_000_000_000, (counts[key] ?? 0) + 1)
        defaults.set(counts, forKey: "localUsageCounts")
    }
    func clear() { counts = [:]; defaults.removeObject(forKey: "localUsageCounts") }
}
