// Store marketing artwork. Production views compiled with APP_STORE; synthetic demo media only.
import AppKit
import SwiftUI
import AVFoundation

let projectRoot = "/Users/yanjun/Desktop/MonoProjs/MonoProjs/DeskCapture"
let outputRoot = projectRoot + "/docs/app-store/screenshots"
let violet = Color(red: 0.38, green: 0.26, blue: 0.70)

struct DemoDocument: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("WEEKEND JOURNAL  /  03").font(.system(size: 13, weight: .semibold, design: .monospaced)).tracking(2)
                Spacer()
                Text("The slow\ncoast.").font(.system(size: 73, weight: .medium, design: .serif)).lineSpacing(-7)
                Text("Less rushing. More remembering.").font(.system(size: 17)).padding(.top, 22)
                Rectangle().frame(width: 52, height: 2).padding(.vertical, 28)
                Text("A little sea air. A longer lunch.\nA place to pause and look again.").font(.system(size: 19)).lineSpacing(7)
                Spacer()
                Text("FIELD NOTES").font(.system(size: 11, weight: .bold)).tracking(2)
                Text("09:00  Coastal walk\n12:30  Lunch by the water\n16:00  Find a quiet corner").font(.system(size: 16)).lineSpacing(9).padding(.top, 14)
                Spacer()
                Text("Notes by Alex · hello@example.com").font(.system(size: 12)).opacity(0.65)
            }.padding(48).frame(width: 480, height: 720).background(Color(red: 0.97, green: 0.95, blue: 0.90))
            Image(nsImage: NSImage(contentsOfFile: projectRoot + "/Sources/DeskCapture/Resources/WorkflowSample.png")!)
                .resizable().scaledToFill().frame(width: 720, height: 720).clipped()
        }.foregroundStyle(Color(red: 0.19, green: 0.23, blue: 0.20)).frame(width: 1200, height: 720)
    }
}

struct StoreArtwork: View {
    let headline: String
    let detail: String
    let number: String
    let content: AnyView
    let dark: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: dark ? 0.12 : 0.965, green: dark ? 0.10 : 0.955, blue: dark ? 0.19 : 0.985)
            // Crop corners echo the icon, with generous empty space around the product.
            Path { p in
                p.move(to: .init(x: 55, y: 320)); p.addLine(to: .init(x: 55, y: 262)); p.addQuadCurve(to: .init(x: 79,y:238), control: .init(x:55,y:238)); p.addLine(to:.init(x:137,y:238))
                p.move(to:.init(x:1385,y:752));p.addLine(to:.init(x:1385,y:810));p.addQuadCurve(to:.init(x:1361,y:834),control:.init(x:1385,y:834));p.addLine(to:.init(x:1303,y:834))
            }.stroke(violet.opacity(dark ? 0.7 : 0.30), style: StrokeStyle(lineWidth: 7,lineCap: .round,lineJoin: .round))
            HStack(spacing: 12) {
                Image(nsImage: NSImage(contentsOfFile: projectRoot + "/docs/design/icons-2026-10-29/app-icon.png")!).resizable().frame(width:42,height:42)
                Text("Shotloom").font(.system(size: 21,weight:.semibold))
                Spacer()
                Text(number + "  /  MAC").font(.system(size:12,weight:.semibold,design:.monospaced)).tracking(2).opacity(0.5)
            }.foregroundStyle(dark ? .white : Color(red:0.18,green:0.13,blue:0.28)).padding(.horizontal,84).padding(.top,35)
            VStack(alignment:.leading,spacing:14) {
                Text(headline).font(.system(size:48,weight:.bold)).tracking(-1.4)
                Text(detail).font(.system(size:20,weight:.regular)).opacity(0.65)
            }.foregroundStyle(dark ? .white : Color(red:0.18,green:0.13,blue:0.28)).padding(.leading,90).padding(.top,100)
            content.frame(width:1200,height:620).background(dark ? Color.black : .white)
                .clipShape(RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.white.opacity(dark ? 0.17 : 0.8)))
                .shadow(color:.black.opacity(dark ? 0.35 : 0.16),radius:28,x:0,y:18)
                .offset(x:120,y:238)
        }.frame(width:1440,height:900)
    }
}

@MainActor enum StoreRender {
    static var windows: [NSWindow] = []
    static func render<V: View>(_ view:V, size:CGSize, path:String, delay:Double=1.5) async throws -> CGImage {
        let host=NSHostingView(rootView:view)
        let window=NSWindow(contentRect:.init(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host;window.setContentSize(size);windows.append(window)
        window.orderFront(nil)
        try await Task.sleep(for:.milliseconds(Int(delay*1000)))
        host.layoutSubtreeIfNeeded()
        guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw NSError(domain:"render",code:1) }
        host.cacheDisplay(in:host.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]), let image=bitmap.cgImage else { throw NSError(domain:"render",code:2) }
        try data.write(to:URL(fileURLWithPath:path));window.orderOut(nil); window.contentView=nil
        return image
    }
    static func makeVideo(_ image:CGImage, url:URL) async throws {
        try await Task.detached {
            let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
            let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1200,AVVideoHeightKey:720])
            let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1200,kCVPixelBufferHeightKey as String:720])
            writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
            for f in 0..<72 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(10)) }
                var buffer:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,1200,720,kCVPixelFormatType_32BGRA,nil,&buffer)
                guard let buffer else { throw NSError(domain:"video",code:1) }
                CVPixelBufferLockBaseAddress(buffer,[])
                let c=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:1200,height:720,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue)!
                c.draw(image,in:.init(x:0,y:0,width:1200,height:720));CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adapter.append(buffer,withPresentationTime:.init(value:Int64(f),timescale:24)) else { throw writer.error! }
            }
            input.markAsFinished();await writer.finishWriting();if writer.status != .completed { throw writer.error! }
        }.value
    }
    static func run() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let home=env["CFFIXED_USER_HOME"],home.hasPrefix("/tmp/deskcapture-ui-store-"),env["DESKCAPTURE_DIAGNOSTIC_DIR"]==home else { throw NSError(domain:"isolation",code:1) }
        NSApp.appearance=NSAppearance(named:.aqua)
        let raw=outputRoot+"/raw";try FileManager.default.createDirectory(atPath:raw,withIntermediateDirectories:true)
        let original=try await render(DemoDocument(),size:.init(width:1200,height:720),path:raw+"/demo.png",delay:0.3)
        let store=CaptureStore(directory:URL(fileURLWithPath:home+"/history",isDirectory:true),pruneOnInit:false,automaticRecovery:false)
        let app=AppCoordinator(store:store,imagePasteboard:NSPasteboard(name:.init("Shotloom.StoreMaterials")),registerHotKeys:false)
        let doc=AnnotationDocument(image:original)
        doc.add(Annotation(tool:.arrow,points:[.init(x:0.32,y:0.63),.init(x:0.59,y:0.50)],color:NSColor.systemPurple,width:8))
        doc.add(Annotation(tool:.rectangle,points:[.init(x:0.033,y:0.36),.init(x:0.34,y:0.67)],color:NSColor.systemPurple,width:5))
        doc.add(Annotation(tool:.redact,points:[.init(x:0.124,y:0.058),.init(x:0.304,y:0.082)]))
        let record=CaptureRecord(id:UUID(),createdAt:Date(),filename:"demo.png",width:original.width,height:original.height,mode:CaptureMode.region.rawValue)
        let parent=NSWindow()
        var recipe=LocalWorkflowRecipe();recipe.name=L10n.language == "zh-Hans" ? "分享前整理" : "Prepare for sharing";recipe.steps=[.configured(.resize),.configured(.beautify),.configured(.watermark)];recipe.steps[2].watermark?.text="COASTAL JOURNAL"
        let ocrDocument=AnnotationDocument(image:original)
        ocrDocument.ocrLines=try await CaptureEngine.recognizeLines(original);ocrDocument.showsOCRLocations=true
        for locale in [L10n.language == "zh-Hans" ? "zh-Hans" : "en-US"] {
            let folder=outputRoot+"/"+locale;try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
            let zh=locale=="zh-Hans"
            let specs:[(String,String,String,AnyView,Bool)] = [
                ("01-annotate",zh ? "截下灵感，清楚表达。":"Capture an idea. Make it clear.",zh ? "箭头、文字、形状与打码，把重点留在画面里。":"Arrows, text, shapes and redaction. Get straight to the point.",AnyView(EditorView(app:app,store:store,document:doc,record:record,parent:parent)),false),
                ("02-beautify",zh ? "截图，也可以好看。":"Give every screenshot a finish.",zh ? "背景、留白、圆角和水印，让分享更出彩。":"Backgrounds, padding, rounded corners and watermarks.",AnyView(BeautifyResultView(source:original,copy:{_ in},save:{_ in},close:{})),true),
                ("03-workflow",zh ? "常用步骤，一次排好。":"Your steps. One workflow.",zh ? "组合缩放、美化和水印，预览后再输出。":"Combine resizing, styling and watermarks. Preview, then deliver.",AnyView(LocalWorkflowView(app:app,recipe:recipe,source:original,close:{})),false),
                ("04-ocr",zh ? "图片里的字，直接用。":"Turn image text into useful text.",zh ? "本机文字识别，原图定位与校对。":"On-device OCR, source highlights and text review.",AnyView(EditorView(storeMaterialsApp:app,store:store,document:ocrDocument,record:record,parent:parent)),true)
            ]
            for (i,spec) in specs.enumerated() {
                let ui=spec.3.environment(\.colorScheme,.light).environment(\.locale,Locale(identifier:locale))
                _=try await render(StoreArtwork(headline:spec.1,detail:spec.2,number:String(format:"%02d",i+1),content:AnyView(ui),dark:spec.4),size:.init(width:1440,height:900),path:folder+"/"+spec.0+".png",delay:2)
            }
        }
        // Provenance is maintained alongside the complete screenshot set.
    }
}

@main enum StoreScreenshotApp {
    static func main() { let a=NSApplication.shared;let d=StoreScreenshotDelegate();a.delegate=d;a.setActivationPolicy(.accessory);a.run();withExtendedLifetime(d){} }
}
@MainActor final class StoreScreenshotDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n:Notification) { Task { do { try await StoreRender.run() } catch { try? String(describing:error).write(toFile:outputRoot+"/render-error.txt",atomically:true,encoding:.utf8) };NSApp.terminate(nil) } }
}
