import SwiftUI

struct WorkflowIcon: Identifiable {
    let id: String
    let title: String
    static let choices: [Self] = [
        .init(id: "bolt.fill", title: L10n.text("闪电")), .init(id: "sparkles", title: L10n.text("美化")),
        .init(id: "wand.and.stars", title: L10n.text("魔法棒")), .init(id: "paintpalette.fill", title: L10n.text("调色板")),
        .init(id: "paintbrush.pointed.fill", title: L10n.text("画笔")), .init(id: "photo", title: L10n.text("图片")),
        .init(id: "photo.stack", title: L10n.text("图片叠层")), .init(id: "camera", title: L10n.text("相机")),
        .init(id: "camera.aperture", title: L10n.text("光圈")), .init(id: "crop", title: L10n.text("裁剪")),
        .init(id: "arrow.up.left.and.arrow.down.right", title: L10n.text("缩放")), .init(id: "arrow.clockwise", title: L10n.text("旋转")),
        .init(id: "textformat", title: L10n.text("文字")), .init(id: "text.viewfinder", title: L10n.text("识别")),
        .init(id: "drop.fill", title: L10n.text("水滴")), .init(id: "seal.fill", title: L10n.text("印章")),
        .init(id: "star.fill", title: L10n.text("星星")), .init(id: "heart.fill", title: L10n.text("爱心")),
        .init(id: "leaf.fill", title: L10n.text("叶子")), .init(id: "flame.fill", title: L10n.text("火焰")),
        .init(id: "sun.max.fill", title: L10n.text("太阳")), .init(id: "moon.fill", title: L10n.text("月亮")),
        .init(id: "cloud.fill", title: L10n.text("云朵")), .init(id: "mountain.2.fill", title: L10n.text("山峰")),
        .init(id: "paperplane.fill", title: L10n.text("纸飞机")), .init(id: "tray.and.arrow.down.fill", title: L10n.text("保存")),
        .init(id: "doc.on.clipboard", title: L10n.text("剪贴板")), .init(id: "square.stack.3d.up", title: L10n.text("叠放")),
        .init(id: "square.and.arrow.up", title: L10n.text("导出")), .init(id: "tag.fill", title: L10n.text("标签")),
        .init(id: "lock.shield", title: L10n.text("隐私")), .init(id: "eye.slash", title: L10n.text("隐藏")),
        .init(id: "checkmark.seal.fill", title: L10n.text("确认")), .init(id: "flag.fill", title: L10n.text("旗帜")),
        .init(id: "bookmark.fill", title: L10n.text("书签")), .init(id: "circle.hexagongrid.fill", title: L10n.text("网格")),
        .init(id: "shippingbox.fill", title: L10n.text("收纳")), .init(id: "cube.fill", title: L10n.text("方块")),
        .init(id: "gearshape.2.fill", title: L10n.text("齿轮")), .init(id: "point.3.connected.trianglepath.dotted", title: L10n.text("流程"))
    ]
    static let symbols = Set(choices.map(\.id))
}

struct WorkflowIconPicker: View {
    @Binding var selection: String
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: selection).font(.system(size: 15)).foregroundStyle(Palette.ice)
                Text(L10n.text("选择图标")).font(.system(size: 12))
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.muted)
            }.frame(maxWidth: .infinity, minHeight: 26)
        }.buttonStyle(StudioButtonStyle(quiet: true, accentHover: true))
            .accessibilityLabel(L10n.text("流程图标")).help(L10n.text("选择截图工具栏中的流程图标"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("流程图标")).font(.system(size: 13, weight: .semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6), spacing: 6) {
                        ForEach(WorkflowIcon.choices) { item in
                            StudioIconButton(title: item.title, symbol: item.id, selected: selection == item.id) {
                                selection = item.id; showing = false
                            }
                        }
                    }
                }.padding(14).foregroundStyle(Palette.white).background(Palette.paper)
            }
    }
}
