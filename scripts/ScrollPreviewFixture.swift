// Development-only visual fixture. No desktop capture, clipboard or user history.
import AppKit
import SwiftUI

@MainActor
final class ScrollPreviewFixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: ScrollCapture!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let width = 800, height = 2100
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(white: 0.97, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
        for index in 0..<7 {
            let y = CGFloat(height - 90 - index * 280)
            let title = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 32, weight: .semibold), .foregroundColor: NSColor.black]
            let body = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.darkGray]
            ("\(index + 1). \(["先看到，再完成", "每次滚动，都有反馈", "回看前面的内容", "接缝清晰可检查", "整图与细节切换", "预览保持轻巧", "完成后直接粘贴"][index])" as NSString)
                .draw(at: CGPoint(x: 48, y: y), withAttributes: title)
            ("这是开发验证画面，用于检查长图预览。" as NSString).draw(at: CGPoint(x: 48, y: y - 50), withAttributes: body)
            ("图片在选区旁展开，工具随手可用。" as NSString).draw(at: CGPoint(x: 48, y: y - 92), withAttributes: body)
            NSColor(calibratedHue: CGFloat(index) / 9 + 0.45, saturation: 0.35, brightness: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: 48, y: y - 202, width: CGFloat(430 + index * 27), height: 72), xRadius: 12, yRadius: 12).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = bitmap.cgImage!
        let stitcher = try! ScrollStitcher(); try! stitcher.append(image)
        // UI state and real file export, without synthesizing scroll input or
        // requesting permissions from the development fixture.
        model = ScrollCapture(stitcher: stitcher, isAutomationTrusted: { !CommandLine.arguments.contains("--denied-automation") }, requestAutomationPermission: {})
        model.onFinish = { [weak self] image, output in
            guard let self else { return }
            let message: String
            switch output {
            case .clipboard: message = "开发验证：复制输出已返回（不写剪贴板）"
            case .file(let url): message = "开发验证：已保存 \(url.lastPathComponent)"
            }
            self.window.contentView = NSHostingView(rootView: VStack(spacing: 12) {
                Text(message).font(.system(size: 12))
                Text("\(image.width) × \(image.height) px").font(.system(size: 11))
                Button("关闭") { NSApp.terminate(nil) }
            }.padding(18).frame(width: 288, height: 464))
        }
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 288, height: 464),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "长图预览 · 开发验证"
        window.contentView = NSHostingView(rootView: ScrollHUD(scroll: model, finish: { [weak self] in Task { await self?.model.finish() } }, save: { [weak self] in
            if let model = self?.model { ScrollFileDialog.present(for: model) }
        }, cancel: { NSApp.terminate(nil) }))
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum ScrollPreviewFixture {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = ScrollPreviewFixtureDelegate(); app.delegate = delegate
        app.run(); withExtendedLifetime(delegate) {}
    }
}
