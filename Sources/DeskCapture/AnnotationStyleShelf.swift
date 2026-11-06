import SwiftUI

struct FavoriteColorShelf: View {
    @ObservedObject var store: AnnotationPresetStore
    @ObservedObject var document: AnnotationDocument
    let focus: () -> Void
    @State private var hex = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("我的色板")).font(.system(size: 14, weight: .semibold)); Spacer()
                Button { if let value = AnnotationPresetStore.hex(document.customColor ?? document.color.color) { store.addColor(value) } } label: { Label(L10n.text("收藏当前"), systemImage: "plus") }
                    .font(.system(size: 13)).buttonStyle(.plain).foregroundStyle(Palette.ice)
            }
            if store.colors.isEmpty { Text(L10n.text("把常用颜色收在这里，下次直接点选。")) .font(.system(size: 13)).foregroundStyle(Palette.muted) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(store.colors, id: \.self) { value in
                    Button { document.customColor = AnnotationPresetStore.color(value); focus() } label: {
                        Circle().fill(Color(nsColor: AnnotationPresetStore.color(value)!)).frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Palette.chrome.opacity(0.25), lineWidth: 1))
                            .overlay { if AnnotationPresetStore.hex(document.customColor ?? document.color.color) == value { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(nsColor: (AnnotationPresetStore.color(value)?.brightnessComponent ?? 0) > 0.65 ? .black : .white)) } }
                    }.buttonStyle(.plain).help(value).accessibilityLabel(L10n.text("使用颜色 \(value)"))
                        .contextMenu { Button(L10n.text("移除 \(value)")) { store.removeColor(value) } }
                }
            }
            HStack(spacing: 6) {
                TextField("#RRGGBB", text: $hex).font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .onSubmit { addHex() }
                Button(L10n.text("添加")) { addHex() }.font(.system(size: 13))
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }.font(.system(size: 13)).controlSize(.small).padding(20).frame(width: 300).foregroundStyle(Palette.white).background(OpticalPanel(radius: 18))
    }
    private func addHex() {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.hasPrefix("#") ? value : "#" + value
        guard let color = AnnotationPresetStore.color(normalized) else { error = L10n.text("请输入六位 HEX，例如 #58CFE3"); return }
        store.addColor(normalized); document.customColor = color; hex = ""; error = nil
    }
}

struct AnnotationStyleShelf: View {
    @ObservedObject var store: AnnotationPresetStore
    @ObservedObject var document: AnnotationDocument
    let tool: AnnotationTool
    let apply: (SavedAnnotationStyle) -> Void
    @State private var name = ""
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.text("常用标注样式")).font(.system(size: 14, weight: .semibold)); Spacer(); Text("\(store.styles.count)/20").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            HStack(spacing: 8) {
                StudioSymbol(name: tool.symbol).foregroundStyle(Color(nsColor: document.customColor ?? document.color.color)).frame(width: 24)
                TextField(L10n.text("给当前样式起个名字"), text: $name).font(.system(size: 13)).textFieldStyle(.roundedBorder).onSubmit { save() }
                Button(saved ? L10n.text("已保存") : L10n.text("保存")) { save() }.font(.system(size: 13))
            }
            if store.styles.isEmpty { Text(L10n.text("暂无常用样式")).foregroundStyle(Palette.muted).padding(.vertical, 8) }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.styles) { style in
                        HStack(spacing: 8) {
                            Button { apply(style) } label: {
                                HStack(spacing: 10) {
                                    StudioSymbol(name: style.tool.symbol).font(.system(size: 16)).foregroundStyle(Color(red: style.rgba[0], green: style.rgba[1], blue: style.rgba[2])).frame(width: 28, height: 32)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(style.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(L10n.text("\(style.tool.title) · \(Int(style.width)) pt")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                                    }
                                    Spacer(); Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(Palette.muted)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { store.remove(style.id) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 20, height: 24) }.buttonStyle(.plain).help(L10n.text("移除样式"))
                        }.padding(.horizontal, 8).padding(.vertical, 5).background(Palette.chrome.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(height: min(240, CGFloat(store.styles.count) * 48))
        }.font(.system(size: 13)).controlSize(.small).padding(20).frame(width: 340).foregroundStyle(Palette.white).background(OpticalPanel(radius: 18))
            .onAppear { name = tool.title }
            .onChange(of: name) { _, _ in saved = false }
    }
    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        store.save(SavedAnnotationStyle(name: String(value.prefix(40)), tool: tool, document: document)); saved = true
    }
}
