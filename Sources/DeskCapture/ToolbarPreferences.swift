import SwiftUI
import AppKit

// Stable identifiers keep saved layouts independent of translated titles.
enum CaptureToolbarItem: String, CaseIterable, Identifiable, Codable {
    case select, color, size, shape, pen, text, mosaic, undo, recognition, pin, save
    case highlight, step, redact, erase, icon, spotlight, magnify, measure
    var id: String { rawValue }
    static let defaults: [Self] = [.select, .color, .size, .shape, .pen, .text, .mosaic, .undo, .recognition, .pin, .save]
    var tool: AnnotationTool? { AnnotationTool(rawValue: rawValue) }
    var title: String {
        switch self {
        case .select: L10n.text("选择标注"); case .color: L10n.text("取色"); case .size: L10n.text("尺寸与比例"); case .shape: L10n.text("形状")
        case .undo: L10n.text("撤销"); case .recognition: L10n.text("文字与内容识别"); case .pin: L10n.text("钉在屏幕"); case .save: L10n.text("保存")
        default: tool?.title ?? rawValue
        }
    }
}

@MainActor
final class ToolbarPreferences: ObservableObject {
    static let shared = ToolbarPreferences()
    @Published private(set) var order: [CaptureToolbarItem]
    @Published private(set) var visible: Set<CaptureToolbarItem>
    private let defaults: UserDefaults
    init(defaults: UserDefaults = AppPreferences.standard) {
        self.defaults = defaults
        let saved = (defaults.stringArray(forKey: "captureToolbarOrder") ?? []).compactMap(CaptureToolbarItem.init(rawValue:))
        var unique: [CaptureToolbarItem] = []
        for item in saved + CaptureToolbarItem.allCases where !unique.contains(item) { unique.append(item) }
        order = unique
        visible = Set((defaults.stringArray(forKey: "captureToolbarVisible") ?? CaptureToolbarItem.defaults.map(\.rawValue)).compactMap(CaptureToolbarItem.init(rawValue:)))
    }
    var displayed: [CaptureToolbarItem] { order.filter { visible.contains($0) } }
    var hidden: [CaptureToolbarItem] { order.filter { !visible.contains($0) } }
    func setVisible(_ item: CaptureToolbarItem, _ value: Bool) {
        if value { visible.insert(item) } else { visible.remove(item) }
        save()
    }
    func move(_ item: CaptureToolbarItem, by offset: Int) {
        guard let index = order.firstIndex(of: item), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset); save()
    }
    // Destination is a gap in the original list, matching NSTableView's drop row.
    func move(_ item: CaptureToolbarItem, toInsertionIndex destination: Int) {
        guard let source = order.firstIndex(of: item), (0...order.count).contains(destination) else { return }
        let target = destination > source ? destination - 1 : destination
        guard target != source else { return }
        var updated = order
        updated.remove(at: source)
        updated.insert(item, at: target)
        order = updated
        save()
    }
    func reset() { order = CaptureToolbarItem.allCases; visible = Set(CaptureToolbarItem.defaults); save() }
    private func save() {
        defaults.set(order.map(\.rawValue), forKey: "captureToolbarOrder")
        defaults.set(order.filter { visible.contains($0) }.map(\.rawValue), forKey: "captureToolbarVisible")
    }
    // History editor shares the annotation part of the capture toolbar layout.
    var editorTools: [AnnotationTool] {
        displayed.flatMap { item in item == .shape ? [.arrow, .rectangle] : item.tool.map { [$0] } ?? [] }
    }
}

struct ToolbarConfigurationView: View {
    @ObservedObject private var preferences = ToolbarPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: L10n.text("工具栏布局")) {
                Button(L10n.text("恢复默认")) { preferences.reset() }.buttonStyle(.bordered)
            }
            Divider()
            ToolbarOrderList(preferences: preferences)
                .frame(height: 352)
        }.font(.system(size: 13))
    }
}

// AppKit owns the drag session, insertion indicator and edge autoscrolling.
// Order changes only on drop, so Escape or dropping outside leaves preferences intact.
private struct ToolbarOrderList: NSViewRepresentable {
    @ObservedObject var preferences: ToolbarPreferences

    func makeCoordinator() -> Coordinator { Coordinator(preferences: preferences) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ToolbarOrderTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("toolbar-item"))
        table.addTableColumn(column)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([Coordinator.itemType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityLabel(L10n.text("工具栏按钮顺序"))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        guard coordinator.order != preferences.order || coordinator.visible != preferences.visible else { return }
        coordinator.order = preferences.order
        coordinator.visible = preferences.visible
        table.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let itemType = NSPasteboard.PasteboardType("com.deskcapture.toolbar-order")
        let preferences: ToolbarPreferences
        var order: [CaptureToolbarItem]
        var visible: Set<CaptureToolbarItem>

        init(preferences: ToolbarPreferences) {
            self.preferences = preferences
            order = preferences.order
            visible = preferences.visible
        }

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = order[row]
            let cell = ToolbarOrderCell()
            cell.configure(item: item, preferences: preferences)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard order.indices.contains(row) else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(order[row].rawValue, forType: Self.itemType)
            return writer
        }

        private func draggedItem(_ info: NSDraggingInfo, table: NSTableView) -> CaptureToolbarItem? {
            guard let source = info.draggingSource as? NSTableView, source === table,
                  let raw = info.draggingPasteboard.string(forType: Self.itemType),
                  let item = CaptureToolbarItem(rawValue: raw), order.contains(item) else { return nil }
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard draggedItem(info, table: tableView) != nil, (0...order.count).contains(row) else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let item = draggedItem(info, table: tableView), (0...order.count).contains(row) else { return false }
            preferences.move(item, toInsertionIndex: row)
            order = preferences.order
            visible = preferences.visible
            tableView.reloadData()
            if let index = order.firstIndex(of: item) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            }
            return true
        }
    }
}

private final class ToolbarOrderTable: NSTableView {
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        mouseDownPoint.x >= 0 && mouseDownPoint.x < 32 && rowIndexes.count == 1
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let handleStrip = NSRect(x: 0, y: visibleRect.minY, width: 32, height: visibleRect.height)
        addCursorRect(handleStrip, cursor: .openHand)
    }
}

private final class ToolbarOrderCell: NSTableCellView {
    // Keep the grip outside NSHostingView so mouse-down reaches NSTableView's native drag handling.
    private let grip = ToolbarOrderGrip()
    private var content: NSHostingView<ToolbarOrderRow>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: L10n.text("拖动排序"))
        grip.contentTintColor = .secondaryLabelColor
        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)
        NSLayoutConstraint.activate([
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            grip.widthAnchor.constraint(equalToConstant: 16),
            grip.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(item: CaptureToolbarItem, preferences: ToolbarPreferences) {
        let hosted = NSHostingView(rootView: ToolbarOrderRow(item: item, preferences: preferences))
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        content = hosted
        setAccessibilityLabel(item.title)
    }
}

private final class ToolbarOrderGrip: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ToolbarOrderRow: View {
    let item: CaptureToolbarItem
    @ObservedObject var preferences: ToolbarPreferences

    var body: some View {
        HStack(spacing: 12) {
            Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
            Toggle(item.title, isOn: Binding(get: { preferences.visible.contains(item) },
                                            set: { preferences.setVisible(item, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                .accessibilityLabel(L10n.text("显示\(item.title)"))
            Menu {
                Button(L10n.text("移到最前")) { preferences.move(item, toInsertionIndex: 0) }
                    .disabled(preferences.order.first == item)
                Button(L10n.text("向前移动")) { preferences.move(item, by: -1) }
                    .disabled(preferences.order.first == item)
                Button(L10n.text("向后移动")) { preferences.move(item, by: 1) }
                    .disabled(preferences.order.last == item)
                Button(L10n.text("移到最后")) { preferences.move(item, toInsertionIndex: preferences.order.count) }
                    .disabled(preferences.order.last == item)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L10n.text("调整\(item.title)的位置")).accessibilityLabel(L10n.text("调整\(item.title)的位置"))
        }
        .font(.system(size: 13)).foregroundStyle(Palette.white).tint(Palette.ice)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct BuiltInShortcutView: View {
    private let groups: [(String, [(String, String)])] = [
        (L10n.text("截图选区"), [(L10n.text("取消截图"), "Esc"), (L10n.text("完成当前捕获"), L10n.text("Enter / 双击选区")), (L10n.text("复制并结束（取色时复制 HEX）"), "⌘C"), (L10n.text("保存图片"), "⌘S"), (L10n.text("切换取色"), "P"), (L10n.text("复制 HEX / RGB（取色时）"), "Tab / ⇧Tab"), (L10n.text("复制 RGB（取色时）"), "⇧⌘C")]),
        (L10n.text("标注编辑"), [(L10n.text("撤销 / 重做"), "⌘Z / ⇧⌘Z"), (L10n.text("全选标注"), "⌘A"), (L10n.text("复制选中标注"), "⌘D"), (L10n.text("删除选中标注"), "Delete / Fn Delete"), (L10n.text("微调选区或标注"), L10n.text("方向键 / ⇧方向键 ×10")), (L10n.text("多选标注"), L10n.text("⇧点击"))]),
        (L10n.text("历史编辑器"), [(L10n.text("复制 / 保存图片"), "⌘C / ⌘S"), (L10n.text("缩小 / 放大"), "⌘− / ⌘+"), (L10n.text("原始比例 / 适应窗口"), "⌘1 / ⌘0")]),
        (L10n.text("应用与钉图"), [(L10n.text("编辑剪贴板"), "⇧⌘V"), (L10n.text("设置 / 退出"), "⌘, / ⌘Q"), (L10n.text("移动钉图 / 关闭钉图"), L10n.text("方向键 / Esc"))])
    ]
    var body: some View {
        DisclosureGroup(L10n.text("截图与编辑快捷键（内置）")) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups.indices, id: \.self) { index in
                    Text(groups[index].0).fontWeight(.semibold)
                    ForEach(groups[index].1.indices, id: \.self) { row in
                        HStack { Text(groups[index].1[row].0); Spacer(); Text(groups[index].1[row].1).monospaced() }
                    }
                }
            }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        }.font(.system(size: 13))
    }
}
