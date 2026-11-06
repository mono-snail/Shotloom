import SwiftUI

private struct OCRFontFittingRequest: Hashable {
    let generation: Int
    let revision: Int
    let lineID: UUID
    let text: String
}

struct OCRFontFittingView: View {
    @ObservedObject var document: AnnotationDocument
    let line: OCRLine
    let text: String
    let done: () -> Void
    @State private var result: OCRFontFittingResult?
    @State private var error: String?
    @State private var loading = true
    @State private var generation = 0
    @State private var measuredRequest: OCRFontFittingRequest?
    private var fitRequest: OCRFontFittingRequest {
        .init(generation: generation, revision: document.renderRevision, lineID: line.id, text: text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.text("字体候选")).font(.headline); Spacer(); Button(L10n.text("完成"), action: done) }
            if loading { ProgressView(L10n.text("正在比较已安装字体…")) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let result {
                Text(L10n.text("原图")).font(.caption).foregroundStyle(.secondary)
                Image(nsImage: NSImage(cgImage: result.source, size: .zero)).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 70)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(result.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(candidate.fit.fontName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Button(L10n.text("采用")) {
                                        guard measuredRequest == fitRequest else {
                                            self.error = L10n.text("内容已变化，请重新拟合。"); return
                                        }
                                        document.ocrFontFits[line.id] = candidate.fit; done()
                                    }
                                }
                                Image(nsImage: NSImage(cgImage: candidate.preview, size: .zero)).resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: 45)
                                Text(String(format: L10n.text("字号 %.1f px · 字距 %+.2f px · 字形差异 %.1f%%"), Double(candidate.fit.sizePixels), Double(candidate.fit.trackingPixels), candidate.fit.maskError*100))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                DisclosureGroup(L10n.text("基线与字重")) {
                                    Text(String(format: L10n.text("基线 %.1f px · 字重 %.2f"), Double(candidate.fit.baselinePixels), candidate.fit.weight)).font(.system(size: 12))
                                }.font(.system(size: 12))
                            }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(maxHeight: 310)
                Text(L10n.text("本次比较 \(result.fontsCompared) 款（已安装 \(result.availableFonts) 款）。只用于本行下一次改写。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("恢复手动字体")) { document.ocrFontFits.removeValue(forKey: line.id); done() }
                Spacer()
                Button(L10n.text("重新拟合")) { generation += 1 }.disabled(loading)
            }
        }.font(.system(size: 13)).controlSize(.small).padding(20).frame(width: 440)
            .task(id: fitRequest) {
                loading = true; result = nil; error = nil
                let request = fitRequest, snapshot = document.original, bounds = line.bounds
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, request == fitRequest else { return }
                    let value = try await OCRFontFitting.fit(image: snapshot, bounds: bounds, text: request.text)
                    guard !Task.isCancelled, request == fitRequest else { return }
                    measuredRequest = request; result = value
                } catch is CancellationError { }
                catch { if !Task.isCancelled, request == fitRequest { self.error = error.localizedDescription } }
                if !Task.isCancelled, request == fitRequest { loading = false }
            }
    }
}

struct OCRFontFittingButton: View {
    @ObservedObject var document: AnnotationDocument
    let line: OCRLine
    let text: String
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Image(systemName: "textformat") }
            .help(document.ocrFontFits[line.id].map { L10n.text("已选 \($0.fontName)，点击查看候选或恢复手动字体") } ?? L10n.text("比较字体、字号与字距候选"))
            .popover(isPresented: $showing) {
                OCRFontFittingView(document: document, line: line, text: text, done: { showing = false })
            }
    }
}
