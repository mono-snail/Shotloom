import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardEditor: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow
    let textView = CodeTextView()
    private var pdfView: PDFView?
    private var pdfSourceData: Data?
    private let previewTextView = NSTextView()
    private var previewPane: NSView?
    private var previewUpdate: DispatchWorkItem?
    private var syntaxTask: Task<Void, Never>?
    private var formatTask: Task<Void, Never>?
    var isFormatting: Bool { formatTask != nil }
    private var revision = 0
    private var extractionTask: Task<Void, Never>?
    private var extractionGeneration = UUID()
    private var saveTask: Task<Void, Never>?
    private var savePanel: NSSavePanel?
    private var saveGeneration = UUID()
    private(set) var isSaving = false
    var hasUnsavedChanges: Bool { dirty }
    private var splitView: NSSplitView?
    private var editorScroll: NSScrollView?
    private var lineRuler: TextLineNumberRuler?
    private let languagePicker = NSPopUpButton()
    private let viewPicker = NSSegmentedControl(labels: [L10n.text("编辑"), L10n.text("分栏"), L10n.text("预览")], trackingMode: .selectOne, target: nil, action: nil)
    private let formatButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var automaticLanguage = true
    private var highlighting = true
    private var wrapsLines = true
    private var fontSize: CGFloat = 14
    private(set) var language: TextLanguage = .plain
    private var dirty = false
    private var suggestedName: String
    private let report: (String) -> Void
    private let openText: (String) -> Void

    init(text: String, name: String, report: @escaping (String) -> Void) {
        suggestedName = name; self.report = report; openText = { _ in }
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 980, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        configureTextView(textView, editable: true)
        textView.string = text; textView.delegate = self
        textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticLinkDetectionEnabled = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = textView; editorScroll = scroll
        let ruler = TextLineNumberRuler(scroll: scroll, editor: textView); lineRuler = ruler
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        configureTextView(previewTextView, editable: false)
        let previewScroll = NSScrollView(); previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true; previewScroll.documentView = previewTextView
        previewPane = pane(title: L10n.text("Markdown 预览"), content: previewScroll)
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(scroll); splitView = split
        configureTextWindow(content: split)
        updateLanguage(); updateStatus(); scheduleSyntax()
        showWindow()
        if language == .markdown { viewPicker.selectedSegment = 1; changeViewMode() }
    }

    private func configureTextView(_ view: NSTextView, editable: Bool) {
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true; view.allowsUndo = editable
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular); view.textColor = .labelColor
        view.textContainerInset = CGSize(width: 16, height: 16); view.isVerticallyResizable = true
        view.frame = CGRect(x: 0, y: 0, width: 760, height: 580)
        view.minSize = .zero; view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.backgroundColor = StudioNativeColor.paper
    }

    private func configureTextWindow(content: NSView) {
        window.title = suggestedName + " — DeskCapture"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = CGSize(width: 780, height: 440)
        languagePicker.controlSize = .small; languagePicker.identifier = NSUserInterfaceItemIdentifier("text.language")
        languagePicker.addItem(withTitle: L10n.text("自动识别")); languagePicker.menu?.addItem(.separator())
        for language in TextLanguage.allCases {
            languagePicker.addItem(withTitle: language.title); languagePicker.lastItem?.representedObject = language.rawValue
        }
        languagePicker.target = self; languagePicker.action = #selector(selectLanguage)
        languagePicker.toolTip = L10n.text("自动识别语言，或手动指定语法高亮")
        viewPicker.controlSize = .small; viewPicker.selectedSegment = 0
        viewPicker.target = self; viewPicker.action = #selector(changeViewMode)
        viewPicker.identifier = NSUserInterfaceItemIdentifier("text.viewMode")
        viewPicker.toolTip = L10n.text("Markdown：编辑、分栏或阅读预览")
        setupButton(formatButton, title: L10n.text("格式化"), symbol: "text.alignleft", action: #selector(formatText), help: L10n.text("格式化 JSON / XML（⇧⌥F）"))
        formatButton.identifier = NSUserInterfaceItemIdentifier("text.format")
        formatButton.keyEquivalent = "f"; formatButton.keyEquivalentModifierMask = [.option, .shift]
        let find = iconButton(symbol: "magnifyingglass", action: #selector(findText), help: L10n.text("查找与替换（⌘F）"))
        find.keyEquivalent = "f"; find.keyEquivalentModifierMask = .command
        let copy = iconButton(symbol: "doc.on.doc", action: #selector(copyContent), help: L10n.text("复制全文"))
        let save = iconButton(symbol: "square.and.arrow.down", action: #selector(saveText), help: L10n.text("另存为…（⌘S）"))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let more = iconButton(symbol: "ellipsis", action: #selector(showMore), help: L10n.text("显示选项与导出格式"))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let title = NSTextField(labelWithString: L10n.text("文字工作台"))
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = StudioNativeColor.accent
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let toolbar = NSStackView(views: [title, languagePicker, viewPicker, spacer, formatButton, find, copy, save, more])
        toolbar.orientation = .horizontal; toolbar.spacing = 8; toolbar.alignment = .centerY
        let top = NSVisualEffectView(); top.material = .headerView; top.blendingMode = .withinWindow
        toolbar.translatesAutoresizingMaskIntoConstraints = false; top.addSubview(toolbar)
        for label in [statusLabel, positionLabel, countLabel] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, positionLabel, countLabel]); footer.spacing = 20
        let root = EditorSurfaceView(); window.contentView = root
        for view in [top, content, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor), top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            top.topAnchor.constraint(equalTo: root.topAnchor), top.heightAnchor.constraint(equalToConstant: 58),
            toolbar.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 18), toolbar.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -12),
            toolbar.centerYAnchor.constraint(equalTo: top.centerYAnchor), languagePicker.widthAnchor.constraint(equalToConstant: 130),
            content.topAnchor.constraint(equalTo: top.bottomAnchor), content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7), footer.heightAnchor.constraint(equalToConstant: 18)
        ])
    }
    private func setupButton(_ button: NSButton, title: String, symbol: String, action: Selector, help: String) {
        button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded
        button.controlSize = .regular; button.contentTintColor = StudioNativeColor.accent; button.font = .systemFont(ofSize: 12)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = help; button.setAccessibilityLabel(help)
    }
    private func iconButton(symbol: String, action: Selector, help: String) -> NSButton {
        let button = NSButton(); setupButton(button, title: "", symbol: symbol, action: action, help: help)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    private func pane(title: String, content: NSView) -> NSView {
        let root = EditorSurfaceView()
        let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = .secondaryLabelColor
        for view in [label, content] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            content.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 9), content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        return root
    }
    private func showWindow() {
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        if pdfView == nil { window.makeFirstResponder(textView) }
    }
    init(pdf: PDFDocument, sourceData: Data, name: String, report: @escaping (String) -> Void, openText: @escaping (String) -> Void) {
        suggestedName = name; self.report = report; self.openText = openText
        pdfSourceData = sourceData
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        let view = PDFView(); view.document = pdf; view.autoScales = true; view.displayMode = .singlePageContinuous; pdfView = view
        configure(content: view, buttons: [(L10n.text("高亮选中文字"), #selector(highlight)), (L10n.text("撤销高亮"), #selector(undoHighlight)), (L10n.text("提取文字"), #selector(extractText)), (L10n.text("另存 PDF…"), #selector(savePDF))])
    }


    private var highlights: [(PDFPage, PDFAnnotation)] = []
    private func configure(content: NSView, buttons: [(String, Selector)]) {
        window.title = suggestedName + " — DeskCapture"; window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = CGSize(width: 620, height: 400)
        let toolbar = NSStackView(views: buttons.map {
            let button = NSButton(title: $0.0, target: self, action: $0.1); button.controlSize = .small; return button
        }); toolbar.spacing = 10
        let root = EditorSurfaceView(); window.contentView = root
        for view in [toolbar, content] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            content.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        showWindow()
    }
    @objc private func selectLanguage() {
        automaticLanguage = languagePicker.indexOfSelectedItem == 0
        if !automaticLanguage, let raw = languagePicker.selectedItem?.representedObject as? String, let selected = TextLanguage(rawValue: raw) { language = selected }
        updateLanguage(); scheduleSyntax(); schedulePreview()
    }
    private func updateLanguage() {
        if automaticLanguage {
            let detected = TextLanguage.detect(textView.string, name: suggestedName)
            let prefix = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).first
            // Do not lose the selected syntax while a pasted document is temporarily incomplete.
            if !(detected == .plain && ((language == .json && (prefix == "{" || prefix == "[")) || (language == .xml && prefix == "<"))) { language = detected }
        }
        languagePicker.item(at: 0)?.title = L10n.text("自动 · ") + language.title
        textView.language = language
        formatButton.isEnabled = language.supportsFormatting
        formatButton.toolTip = language.supportsFormatting ? L10n.text("格式化 \(language.title)（⇧⌥F）") : L10n.text("格式化支持 JSON 和 XML")
        viewPicker.isHidden = language != .markdown
        if language != .markdown { viewPicker.selectedSegment = 0; changeViewMode() }
        updateStatus()
    }
    @objc func changeViewMode() {
        guard let split = splitView, let scroll = editorScroll, let preview = previewPane else { return }
        let mode = language == .markdown ? viewPicker.selectedSegment : 0
        // Keep the editable view alive so undo and unsaved source survive every mode.
        if mode == 0 {
            preview.removeFromSuperview()
            if scroll.superview == nil { split.addArrangedSubview(scroll) }
        } else if mode == 2 {
            scroll.removeFromSuperview()
            if preview.superview == nil { split.addArrangedSubview(preview) }
        } else {
            preview.removeFromSuperview(); scroll.removeFromSuperview()
            split.addArrangedSubview(scroll); split.addArrangedSubview(preview)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        if mode == 1 { split.setPosition(split.bounds.width / 2, ofDividerAt: 0) }
        if mode != 0 { refreshPreview() } else { previewUpdate?.cancel() }
        if mode != 2 { window.makeFirstResponder(textView) }
    }
    func textDidChange(_ notification: Notification) {
        dirty = true; window.isDocumentEdited = true
        lineRuler?.refreshLines(); updateLanguage(); scheduleSyntax(); schedulePreview()
    }
    func textViewDidChangeSelection(_ notification: Notification) { updatePosition(); lineRuler?.needsDisplay = true }
    private func updatePosition() {
        let location = min(textView.selectedRange().location, (textView.string as NSString).length)
        let line = lineRuler?.lineIndex(at: location) ?? 0
        let start = lineRuler?.lineStarts[line] ?? 0
        let column = (textView.string as NSString).substring(with: NSRange(location: start, length: max(0, location - start))).count + 1
        positionLabel.stringValue = L10n.text("行 \(line + 1)，列 \(column)")
    }
    private func updateStatus() {
        let encoding = language == .xml ? XMLTextFormatter.encodingName(in: textView.string) : "UTF-8"
        countLabel.stringValue = L10n.text("\(lineRuler?.lineStarts.count ?? 1) 行   \(encoding)")
        if (textView.string as NSString).length > 1_000_000 { setStatus(L10n.text("大文本模式 · 高亮已暂停")) }
        else { setStatus(language.title + (highlighting && language != .plain ? L10n.text(" · 语法高亮") : "")) }
        updatePosition()
    }
    private func setStatus(_ message: String, error: Bool = false) {
        statusLabel.stringValue = message; statusLabel.toolTip = message
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }
    private func scheduleSyntax() {
        syntaxTask?.cancel(); revision += 1
        let currentRevision = revision
        guard let layout = textView.layoutManager else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        guard highlighting, range.length <= 1_000_000, language != .plain else {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range); return
        }
        let source = textView.string, language = language
        syntaxTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let tokens = await Task.detached(priority: .userInitiated) { TextSyntaxHighlighter.tokens(in: source, language: language) }.value
            guard !Task.isCancelled, let self, self.revision == currentRevision, let layout = self.textView.layoutManager else { return }
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for token in tokens { layout.addTemporaryAttribute(.foregroundColor, value: token.kind.color, forCharacterRange: token.range) }
            self.textView.needsDisplay = true
        }
    }
    private func schedulePreview() {
        previewUpdate?.cancel()
        guard language == .markdown, previewPane?.superview != nil else { return }
        let update = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        previewUpdate = update; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: update)
    }
    private func refreshPreview() {
        previewUpdate?.cancel(); previewUpdate = nil
        let preview: NSAttributedString
        if textView.string.utf8.count > 500_000 {
            preview = NSAttributedString(string: L10n.text("此文本较大，请使用编辑视图。Markdown 预览支持 500 KB 以内的内容。"), attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])
        } else { preview = MarkdownPreview.render(textView.string) }
        previewTextView.textStorage?.setAttributedString(preview)
    }
    @objc func formatText() {
        guard language.supportsFormatting, formatTask == nil else { return }
        let source = textView.string, language = language, version = revision
        if source.utf8.count <= 100_000 {
            do { applyFormatting(try language == .xml ? XMLTextFormatter.format(source) : JSONTextFormatter.format(source), language: language) }
            catch { setStatus(error.localizedDescription, error: true) }
            return
        }
        setStatus(L10n.text("正在格式化…")); formatButton.isEnabled = false
        formatTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { try language == .xml ? XMLTextFormatter.format(source) : JSONTextFormatter.format(source) }
            do {
                let formatted = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                guard let self else { return }
                defer { self.formatTask = nil; self.formatButton.isEnabled = self.language.supportsFormatting }
                guard self.revision == version else { self.setStatus(L10n.text("内容已变化，已取消应用格式化结果")); return }
                self.applyFormatting(formatted, language: language)
            } catch {
                guard let self else { return }
                self.formatTask = nil; self.formatButton.isEnabled = self.language.supportsFormatting
                if !Task.isCancelled { self.setStatus(error.localizedDescription, error: true) }
            }
        }
    }
    private func applyFormatting(_ formatted: String, language: TextLanguage) {
        guard formatted != textView.string else { setStatus(L10n.text("\(language.title) 已是格式化形式")); return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: range, replacementString: formatted) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: formatted); textView.didChangeText()
        textView.undoManager?.setActionName(L10n.text("格式化 ") + language.title)
        setStatus(L10n.text("\(language.title) 已格式化 · ⌘Z 撤销"))
    }
    @objc private func findText() {
        if editorScroll?.superview == nil { viewPicker.selectedSegment = 0; changeViewMode() }
        window.makeFirstResponder(textView)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
    }
    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool? = nil, tag: Int = 0) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.tag = tag
            if let checked { item.state = checked ? .on : .off }; menu.addItem(item)
        }
        add(L10n.text("语法高亮"), #selector(toggleHighlighting), checked: highlighting)
        add(L10n.text("自动换行"), #selector(toggleWrapping), checked: wrapsLines)
        menu.addItem(.separator())
        add(L10n.text("放大文字"), #selector(changeFontSize), tag: 1); add(L10n.text("缩小文字"), #selector(changeFontSize), tag: -1)
        add(L10n.text("还原文字大小"), #selector(changeFontSize), tag: 0)
        menu.addItem(.separator())
        for format in [TextLanguage.plain, .markdown, .json, .xml] { add(L10n.text("另存为 ") + format.title + "…", #selector(exportText), tag: TextLanguage.allCases.firstIndex(of: format)!) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
    @objc private func toggleHighlighting() { highlighting.toggle(); scheduleSyntax(); updateStatus() }
    @objc private func toggleWrapping() {
        wrapsLines.toggle()
        guard let scroll = editorScroll else { return }
        scroll.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = CGSize(width: wrapsLines ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if wrapsLines { textView.setFrameSize(CGSize(width: scroll.contentSize.width, height: textView.frame.height)) }
        textView.needsDisplay = true; lineRuler?.needsDisplay = true
    }
    @objc private func changeFontSize(_ sender: NSMenuItem) {
        fontSize = sender.tag == 0 ? 14 : min(28, max(10, fontSize + CGFloat(sender.tag)))
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.typingAttributes = [.font: textView.font!, .foregroundColor: NSColor.labelColor]
        lineRuler?.needsDisplay = true
    }
    @objc private func exportText(_ sender: NSMenuItem) { saveLanguage(TextLanguage.allCases[sender.tag]) }
    @objc private func saveText() { saveLanguage(language) }
    private func saveLanguage(_ language: TextLanguage) {
        let originalExtension = (suggestedName as NSString).pathExtension.lowercased()
        let ext = TextLanguage.fromExtension(originalExtension) == language ? originalExtension : language.fileExtension
        save(ext: ext, type: UTType(filenameExtension: ext) ?? .plainText)
    }
    func windowWillClose(_ notification: Notification) {
        previewUpdate?.cancel(); previewUpdate = nil; syntaxTask?.cancel(); formatTask?.cancel()
        extractionGeneration = UUID(); extractionTask?.cancel(); extractionTask = nil
        saveGeneration = UUID(); saveTask?.cancel(); saveTask = nil
        savePanel?.cancel(nil); savePanel = nil; isSaving = false
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSaving else { report(L10n.text("正在保存文件，请完成后再关闭。")); return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = L10n.text("关闭并放弃未保存的修改？"); alert.informativeText = L10n.text("可先取消，使用另存按钮保存文件。")
        alert.addButton(withTitle: L10n.text("取消")); alert.addButton(withTitle: L10n.text("放弃修改"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func copyContent() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(textView.string, forType: .string)
        setStatus(L10n.text("全文已复制")); report(L10n.text("文本已复制。"))
    }
    @objc private func savePDF() { save(ext: "pdf", type: .pdf) }
    private func save(ext: String, type: UTType) {
        guard !isSaving else { report(L10n.text("当前文件正在保存。")); return }
        let generation = UUID(); saveGeneration = generation; isSaving = true
        let panel = NSSavePanel(); savePanel = panel; panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (suggestedName as NSString).deletingPathExtension + "." + ext
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, generation == saveGeneration else { return }
            savePanel = nil
            guard response == .OK, let url = panel.url else { isSaving = false; return }
            let snapshot: ClipboardSaveSnapshot
            if let document = pdfView?.document {
                guard let sourceData = pdfSourceData else { isSaving = false; report(L10n.text("PDF 保存源已失效。")); return }
                do { snapshot = try .capturePDF(sourceData: sourceData, document: document, highlights: highlights) }
                catch { isSaving = false; report(error.localizedDescription); return }
            } else { snapshot = .text(textView.string, xml: TextLanguage.fromExtension(ext) == .xml) }
            let savedRevision = revision
            setStatus(L10n.text("正在保存…")); window.subtitle = L10n.text("正在保存…")
            saveTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if generation == saveGeneration { isSaving = false; saveTask = nil; window.subtitle = "" }
                }
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try CaptureImageExport.writeEncoded(snapshot.encoded(), to: url)
                    }
                    try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard generation == saveGeneration, !Task.isCancelled else { return }
                    if revision == savedRevision { dirty = false; window.isDocumentEdited = false }
                    setStatus(revision == savedRevision ? L10n.text("文件已保存") : L10n.text("已保存所选版本，仍有新修改"))
                    report(L10n.text("文件已保存。"))
                } catch {
                    guard generation == saveGeneration, !Task.isCancelled else { return }
                    setStatus(L10n.text("保存失败")); report(L10n.text("保存失败：\(error.localizedDescription)"))
                }
            }
        }
    }
    @objc private func highlight() {
        guard let selection = pdfView?.currentSelection, !(selection.string ?? "").isEmpty else { report(L10n.text("请先在 PDF 中选择文字；扫描件需先 OCR。")) ; return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                annotation.color = .systemYellow; page.addAnnotation(annotation); highlights.append((page, annotation))
            }
        }
        revision += 1; dirty = true; window.isDocumentEdited = true; pdfView?.clearSelection()
    }
    @objc private func undoHighlight() {
        guard let (page, annotation) = highlights.popLast() else { return }; page.removeAnnotation(annotation)
        revision += 1; dirty = true; window.isDocumentEdited = true
    }
    @objc private func extractText() {
        guard extractionTask == nil else { return }
        guard let source = pdfView?.document, source.allowsCopying else { report(L10n.text("这个 PDF 不允许提取文字。")); return }
        guard let sourceData = pdfSourceData else { report(L10n.text("PDF 文字提取源已失效。")); return }
        let generation = UUID(); extractionGeneration = generation
        if !isSaving { window.subtitle = L10n.text("正在提取文字…") }
        extractionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == extractionGeneration {
                    extractionTask = nil
                    if !isSaving { window.subtitle = "" }
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    guard let snapshot = PDFDocument(data: sourceData) else { throw CaptureError.message(L10n.text("PDF 无法读取文字提取源。")) }
                    let text = try ClipboardSaveSnapshot.extractedText(from: snapshot)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureError.message(L10n.text("PDF 没有可提取的文字，可能是扫描件。")) }
                    return text
                }
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, generation == extractionGeneration, window.isVisible else { return }
                openText(text)
            } catch {
                if !Task.isCancelled, generation == extractionGeneration { report(error.localizedDescription) }
            }
        }
    }
}
