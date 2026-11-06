import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class BeautifyWindow: NSWindow, NSWindowDelegate {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        delegate = self
    }
    func windowWillClose(_ notification: Notification) {
        // The coordinator retains closed windows until the next editor opens.
        // Detach the hosting tree now so its tasks and source image can release.
        contentView = nil
    }
}

/// An explicit source chooser: opening the tool never reads the clipboard or
/// writes an imported image to history without a separate user action.
struct BeautifyWorkspaceView: View {
    @ObservedObject var store: CaptureStore
    let pasteboard: NSPasteboard
    let copy: (CGImage) -> Void
    let save: (CGImage) -> Void
    let close: () -> Void
    var isPresented: () -> Bool = { true }
    @State private var source: CGImage?
    @State private var sourceWatermark: ImageWatermark?
    @State private var sourceRevision = UUID()
    @State private var loading = false
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var sourcePanel: NSOpenPanel?
    @State private var request = UUID()
    @State private var visible = true
    @State private var preparingDelivery = false
    @StateObject private var feedback: ImageDeliveryFeedback

    init(store: CaptureStore, pasteboard: NSPasteboard, source: CGImage? = nil, watermark: ImageWatermark? = nil,
         copy: @escaping (CGImage) -> Void, save: @escaping (CGImage) -> Void, close: @escaping () -> Void,
         isPresented: @escaping () -> Bool = { true }, feedback: ImageDeliveryFeedback? = nil) {
        self.store = store; self.pasteboard = pasteboard
        self.copy = copy; self.save = save; self.close = close
        self.isPresented = isPresented
        _source = State(initialValue: source)
        _sourceWatermark = State(initialValue: watermark)
        _feedback = StateObject(wrappedValue: feedback ?? ImageDeliveryFeedback())
    }

    var body: some View {
        ZStack {
            if let source {
                BeautifyResultView(source: source, copy: copy, save: save, close: close, initialWatermark: sourceWatermark,
                    chooseSource: chooseImage, pasteSource: pasteImage,
                    isPresented: { visible && !loading && isPresented() },
                    deliveryStateChanged: { preparingDelivery = $0 },
                    output: feedback.state, cancelOutput: { feedback.cancel() }, dismissOutputError: { feedback.dismissError() })
                    .id(sourceRevision)
                    .disabled(loading)
            } else {
                StudioWorkspace(title: L10n.text("图片美化"), symbol: "sparkles") {
                    EmptyView()
                } preview: {
                    VStack(spacing: 24) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Palette.ice)
                            .accessibilityHidden(true)
                        Text(L10n.text("选择要美化的图片")).font(.system(size: 22, weight: .semibold))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { sourceActions }.fixedSize()
                            VStack(spacing: 12) { sourceActions }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(loading)
                } inspector: {
                    InspectorGroup(L10n.text("最近截图"), initiallyExpanded: true) {
                        if store.isLoading {
                            ProgressView(L10n.text("正在加载历史…"))
                        } else if store.records.isEmpty {
                            Text(L10n.text("暂无截图")).foregroundStyle(Palette.muted)
                        } else {
                            ForEach(Array(store.records.prefix(6))) { record in
                                Button { load(.file(store.url(for: record)), record: record) } label: {
                                    HStack(spacing: 12) {
                                        HistoryThumbnailView(url: store.url(for: record))
                                            .frame(width: 64, height: 48).clipped()
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(record.title).lineLimit(1)
                                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(8).contentShape(Rectangle())
                                }.buttonStyle(StudioNavigationStyle()).disabled(loading)
                                    .accessibilityLabel(L10n.text("美化\(record.title)"))
                            }
                        }
                    }
                } actions: {
                    Text(L10n.text("\(store.records.count) 张截图")).monospacedDigit().foregroundStyle(Palette.muted)
                    Spacer()
                }
            }
        }
        .overlay {
            if loading {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在读取图片…"))
                    Button(L10n.text("取消"), action: cancelLoad)
                }.padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .background {
            Button(L10n.text("选择美化图片…"), action: chooseImage).keyboardShortcut("o", modifiers: .command)
                .disabled(preparingDelivery || loading || feedback.state.busy)
                .buttonStyle(.plain).focusable(false).frame(width: 0, height: 0).clipped().accessibilityHidden(true)
        }
        .alert(L10n.text("无法打开图片"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.text("好")) { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { visible = true }
        .onDisappear { visible = false; cancelSourcePanel(); cancelLoad(); feedback.invalidate() }
    }

    @ViewBuilder private var sourceActions: some View {
        Button(L10n.text("选择图片…"), action: chooseImage).buttonStyle(StudioButtonStyle(primary: true, command: true))
        Button(L10n.text("从剪贴板"), action: pasteImage)
    }

    private func chooseImage() {
        guard sourcePanel == nil, !preparingDelivery, !loading, !feedback.state.busy, visible, isPresented() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.message = L10n.text("选择要美化的图片")
        sourcePanel = panel
        panel.begin { response in
            guard sourcePanel === panel else { return }
            sourcePanel = nil
            guard response == .OK, let url = panel.url, visible, isPresented() else { return }
            load(.file(url))
        }
    }

    private func cancelSourcePanel() {
        let panel = sourcePanel
        sourcePanel = nil // Reject the completion before AppKit sends cancel.
        panel?.cancel(nil)
    }

    private func pasteImage() {
        guard sourcePanel == nil, !preparingDelivery, !loading, !feedback.state.busy, visible, isPresented() else { return }
        do {
            // Snapshot only the explicitly requested representation before decoding.
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                guard urls.count == 1 else { throw CaptureError.message(L10n.text("请一次选择一张图片。")) }
                load(.file(urls[0])); return
            }
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = pasteboard.data(forType: type) { load(.data(data)); return }
            }
            if let string = pasteboard.string(forType: .string), let url = ClipboardContent.filePath(string) {
                load(.file(url)); return
            }
            throw CaptureError.message(L10n.text("剪贴板中没有图片。请复制图片或一个图片文件后重试。"))
        } catch { self.error = error.localizedDescription }
    }

    private func cancelLoad() {
        request = UUID(); loadTask?.cancel(); loadTask = nil; loading = false
    }

    private func load(_ input: BeautifyImageInput, record: CaptureRecord? = nil) {
        cancelLoad()
        let token = UUID(); request = token; loading = true; error = nil
        loadTask = Task { @MainActor in
            defer { if request == token { loading = false; loadTask = nil } }
            do {
                let worker = Task.detached(priority: .userInitiated) { try input.decode() }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, request == token, visible, isPresented() else { return }
                if let record, !store.records.contains(where: { $0.id == record.id && $0.filename == record.filename }) {
                    throw CaptureError.message(L10n.text("这张截图已不在历史中，请重新选择。"))
                }
                feedback.invalidate()
                source = image; sourceWatermark = nil; sourceRevision = UUID()
            } catch is CancellationError { }
            catch { if !Task.isCancelled, request == token, visible { self.error = error.localizedDescription } }
        }
    }
}

private enum BeautifyImageInput: Sendable {
    case file(URL), data(Data)

    func decode() throws -> CGImage {
        try Task.checkCancellation()
        let source: CGImageSource?
        switch self {
        case .file(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 100_000_000 else {
                throw CaptureError.message(L10n.text("请选择不超过 100 MB 的本地图片文件。"))
            }
            // Materialize while the security scope is held; decoding stays off-main.
            return try Self.decode(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        case .data(let data):
            guard data.count <= 100_000_000 else { throw CaptureError.message(L10n.text("剪贴板图片超过 100 MB。")) }
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        return try Self.decode(source)
    }

    private static func decode(_ source: CGImageSource?) throws -> CGImage {
        guard let source,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= 60_000,
              Double(width) * Double(height) <= 80_000_000 else {
            throw CaptureError.message(L10n.text("图片无法读取，或超过 8000 万像素。"))
        }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary) else { throw CaptureError.message(L10n.text("图片无法解码。")) }
        try Task.checkCancellation()
        return image
    }
}
