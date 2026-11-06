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

// This material uses the actual production editor and two generated demo movies.
// Capture the visible window via CUA: AVPlayerLayer is absent from cacheDisplay bitmaps.
@MainActor enum RecordingStoreRender {
    static var window: NSWindow!
    static var screenURL: URL!
    static func renderDemo<V:View>(_ view:V, size:CGSize, path:String) throws -> CGImage {
        let host=NSHostingView(rootView:view);host.frame=NSRect(origin:.zero,size:size)
        host.layoutSubtreeIfNeeded()
        guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw NSError(domain:"render",code:1) }
        host.cacheDisplay(in:host.bounds,to:rep)
        guard let image=rep.cgImage,let png=rep.representation(using:.png,properties:[:]) else { throw NSError(domain:"render",code:2) }
        try png.write(to:URL(fileURLWithPath:path));return image
    }
    static func makeVideo(_ image:CGImage, url:URL) async throws {
        try await Task.detached {
            let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
            let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1200,AVVideoHeightKey:720])
            let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1200,kCVPixelBufferHeightKey as String:720])
            writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
            for f in 0..<144 {
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

    static func show(zh:Bool) {
        let view=StoreArtwork(headline:zh ? "屏幕、镜头，一起录。" : "Your screen. Your camera. One video.",
            detail:zh ? "同步录屏与摄像头画中画，剪辑后导出视频。" : "Record your screen and camera. Edit, then export your video.",
            number:"02",content:AnyView(VideoResultView(url:screenURL,cameraWasRequested:true,close:{},initialTool:.picture).environment(\.colorScheme,.light).environment(\.locale,Locale(identifier:zh ? "zh-Hans" : "en-US"))),dark:false)
        if window == nil {
            window=NSWindow(contentRect:NSRect(x:100,y:100,width:1440,height:900),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
        }
        window.title=zh ? "Shotloom 录屏商店图 · 中文" : "Shotloom Recording Store Artwork · English"
        window.contentView=NSHostingView(rootView:view)
        window.setContentSize(NSSize(width:1440,height:900));window.center();window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    static func prepare() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let home=env["CFFIXED_USER_HOME"],home.hasPrefix("/tmp/deskcapture-ui-store-"),env["DESKCAPTURE_DIAGNOSTIC_DIR"]==home else { throw NSError(domain:"isolation",code:1) }
        NSApp.appearance=NSAppearance(named:.aqua)
        let folder=URL(fileURLWithPath:home).appendingPathComponent("recording-demo",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let screen=try renderDemo(DemoDocument(),size:CGSize(width:1200,height:720),path:folder.appendingPathComponent("screen.png").path)
        let portrait=NSImage(contentsOfFile:outputRoot+"/demo-assets/presenter-generated.png")!
        let camera=try renderDemo(Image(nsImage:portrait).resizable().scaledToFill().frame(width:1200,height:720).clipped(),size:CGSize(width:1200,height:720),path:folder.appendingPathComponent("camera.png").path)
        screenURL=folder.appendingPathComponent(L10n.language == "zh-Hans" ? "录屏演示.mp4" : "Screen recording demo.mp4")
        try await makeVideo(screen,url:screenURL)
        try await makeVideo(camera,url:RecordingCamera.url(for:screenURL))
        var effects=RecordingEffectsOptions();effects.camera.width=0.30;effects.camera.x=0.80;effects.camera.y=0.78;effects.camera.mirrored=false
        effects.style = .aurora
        try RecordingStudioProject(lenses:[],effects:effects).save(screenURL)
        show(zh:L10n.language == "zh-Hans")
    }
}
@main enum RecordingStoreApp {
    static func main() { let app=NSApplication.shared;let delegate=RecordingStoreDelegate();app.delegate=delegate;app.setActivationPolicy(.regular);app.run();withExtendedLifetime(delegate){} }
}
@MainActor final class RecordingStoreDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        Task { do { try await RecordingStoreRender.prepare() } catch { try? String(describing:error).write(toFile:outputRoot+"/recording-render-error.txt",atomically:true,encoding:.utf8);NSApp.terminate(nil) } }
    }
}
