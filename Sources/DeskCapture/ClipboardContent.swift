import AppKit
import UniformTypeIdentifiers

/// Detection runs only when the user asks to edit the clipboard.
enum ClipboardContent {
    case files([URL]), image(NSImage), pdf(Data), text(String)

    static func read(_ pasteboard: NSPasteboard) throws -> ClipboardContent {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        if let data = pasteboard.data(forType: .pdf) { return .pdf(data) }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage { return .image(image) }
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            if let url = filePath(string) { return .files([url]) }
            return .text(string)
        }
        throw CaptureError.message(L10n.text("剪贴板内容暂不支持。可编辑文字、图片、PDF，以及支持的本地文件。"))
    }

    static func filePath(_ string: String) -> URL? {
        var path = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("\n") else { return nil }
        if path.count > 1, (path.first == "\"" && path.last == "\"" || path.first == "'" && path.last == "'") { path = String(path.dropFirst().dropLast()) }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    enum FileKind { case text, image, pdf, video, project }
    static func kind(_ url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "deskcap" { return .project }
        if ext == "pdf" { return .pdf }
        if TextLanguage.fromExtension(ext) != nil { return .text }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .plainText) { return .text }
        return nil
    }

    static func loadText(_ url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw CaptureError.message(L10n.text("文本超过 10 MB，请用专门的文本编辑器打开。")) }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
    }
}
