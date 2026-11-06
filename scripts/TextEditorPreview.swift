import AppKit

@MainActor
final class TextEditorPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let directory = URL(fileURLWithPath: "/tmp/deskcapture-text-editor-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
          "project": "DeskCapture",
          "version": "0.13",
          "enabled": true,
          "editor": {
            "language": "自动识别",
            "fontSize": 14,
            "features": ["syntax highlighting", "line numbers", "formatting"]
          },
          "description": "编辑剪贴板，整理代码与笔记"
        }
        """
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <project name="DeskCapture" version="0.13">
          <!-- 本地文本编辑器 -->
          <editor language="xml" wrap="true">
            <feature enabled="true">语法高亮</feature>
            <feature enabled="true">自动缩进</feature>
            <content>保留 <strong>混合文本</strong> 与实体 &amp; 空格</content>
          </editor>
        </project>
        """
        let markdown = """
        # DeskCapture 文本编辑器

        直接编辑剪贴板里的笔记、代码和配置文件。

        ## 常用操作
        - **自动识别** JSON、XML 和常见代码语言
        - 通过 `⌘F` 查找，使用 `⇧⌥F` 格式化
        - 点击保存图标，另存为本地文件

        > 预览随编辑更新，复制和保存使用源码。

        ```swift
        let editor = ClipboardEditor(text: notes, name: "notes.md")
        ```
        """
        let python = """
        from pathlib import Path

        # 批量读取本地 Markdown 笔记
        def read_notes(directory: str) -> list:
            files = Path(directory).glob("*.md")
            result = []
            for file in files:
                content = file.read_text(encoding="utf-8")
                if content:
                    result.append({"name": file.name, "text": content})
            return result

        notes = read_notes("./docs")
        print(f"共读取 {len(notes)} 篇笔记")
        """
        for (label, text, name, appearance, width) in [
            ("json-light", json, "project.json", NSAppearance.Name.aqua, CGFloat(980)),
            ("xml-dark", xml, "project.xml", .darkAqua, 980),
            ("markdown-light", markdown, "notes.md", .aqua, 980),
            ("python-compact", python, "notes.py", .aqua, 780)
        ] {
            NSApp.appearance = NSAppearance(named: appearance)
            let editor = ClipboardEditor(text: text, name: name, report: { _ in })
            editor.window.setContentSize(CGSize(width: width, height: 580))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
            guard let root = editor.window.contentView else { continue }
            root.layoutSubtreeIfNeeded()
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent(label + ".png"))
                }
            }
            editor.window.delegate = nil; editor.window.close()
        }
        print("Text editor previews: \(directory.path)")
        NSApp.terminate(nil)
    }
}
@main enum TextEditorPreview {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = TextEditorPreviewDelegate(); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
