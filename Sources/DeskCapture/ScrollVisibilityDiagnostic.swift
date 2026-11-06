import AppKit
import ScreenCaptureKit

@MainActor
enum ScrollVisibilityDiagnostic {
    static func run(root: URL) async throws -> [String: Any] {
        let fixture=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ScrollFixtureTarget.app")
        let metadata=root.appendingPathComponent("visibility-fixture.json"),control=metadata.appendingPathExtension("cover")
        let config=NSWorkspace.OpenConfiguration()
        config.arguments=[metadata.path,"--safe-position","--initial-y=0","--visibility-control","--owner-pid=\(ProcessInfo.processInfo.processIdentifier)"]
        config.createsNewApplicationInstance=true;config.activates=true
        if let home=ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { config.environment=["CFFIXED_USER_HOME":home] }
        let application=try await NSWorkspace.shared.openApplication(at:fixture,configuration:config)
        let model=ScrollCapture()
        defer { application.terminate();Task { await model.cancel() } }
        func state() -> [String:Any]? {
            guard let data=try? Data(contentsOf:metadata),data.count<=64_000 else { return nil }
            return try? JSONSerialization.jsonObject(with:data) as? [String:Any]
        }
        for _ in 0..<100 where state()==nil { try await Task.sleep(for:.milliseconds(50)) }
        guard let initial=state(),let coordinates=initial["rect"] as? [Double],coordinates.count==4 else { throw CaptureError.message("可见性夹具未准备好。") }
        let world=CGRect(x:coordinates[0],y:coordinates[1],width:coordinates[2],height:coordinates[3])
        guard let screen=NSScreen.screens.first(where:{$0.frame.contains(world)}) else { throw CaptureError.message("可见性夹具不在当前显示器内。") }
        let rect=world.offsetBy(dx:-screen.frame.minX,dy:-screen.frame.minY)
        let engine=CaptureEngine(), content=try await engine.content()
        guard let target=content.windows.filter({$0.owningApplication?.processID==application.processIdentifier && $0.windowLayer==0 && $0.isOnScreen})
            .max(by:{$0.frame.width*$0.frame.height<$1.frame.width*$1.frame.height}) else { throw CaptureError.message("自有目标窗口缺失。") }
        guard let selectedInfo = CaptureWindowInfo.read(target.windowID),
              selectedInfo.id == target.windowID, selectedInfo.processID == application.processIdentifier,
              ScrollCapture.targetUnchanged(target.frame, selectedInfo.frame) else {
            throw CaptureError.message("真实窗口ID查询未返回所选夹具窗口的位置。")
        }
        let verified: CGImage
        do { verified=try await engine.visibleRegion(rect,screen:screen,content:content,target:target) }
        catch {
            let geometry=try DesktopTopology.current().display(for:screen)
            guard let display=content.displays.first(where:{$0.displayID==geometry.id}) else { throw error }
            let filter=SCContentFilter(display:display,including:[target]);filter.includeMenuBar=false
            let config=SCStreamConfiguration();config.sourceRect=try geometry.sourceRect(rect)
            config.width=Int(rect.width*geometry.scale);config.height=Int(rect.height*geometry.scale)
            config.showsCursor=false;config.captureResolution = .best;config.shouldBeOpaque=false
            let actual=try await engine.region(rect,screen:screen,content:content)
            let reference=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            let metrics=try await Task.detached { try Self.difference(actual,reference) }.value
            throw CaptureError.message("可见性校准失败：\(metrics)，参考区域\(filter.contentRect)，源区域\(config.sourceRect)，目标\(target.frame)")
        }
        let scale=screen.backingScaleFactor
        let exact=try await Task.detached {
            let expected=WorkflowCorpus.textureRows(width:Int(world.width*scale),start:0,height:Int(world.height*scale),seed:42)
            return try ScrollFrameVisibility.matches(display:verified,target:expected)
        }.value
        guard exact else { throw CaptureError.message("可见性核对未保留生成夹具原像素。") }
        // A normal drag on Retina can select an odd number of pixels. SCK
        // must not add transparent padding or rescale that selection.
        let fractional = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 0.5)
        let oddFrame = try await engine.visibleRegion(fractional, screen: screen, content: content, target: target)
        let oddExact = try await Task.detached {
            let offset = Int((0.5 * scale).rounded())
            guard let expected = verified.cropping(to: CGRect(x: 0, y: offset,
                    width: verified.width, height: Int(fractional.height * scale))) else { return false }
            return try ScrollFrameVisibility.matches(display: oddFrame, target: expected)
        }.value
        guard oddExact else { throw CaptureError.message("半点长图选区被补透明边缘或缩放。") }
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let windowRect = CGRect(x: target.frame.minX - screen.frame.minX,
                                y: desktopTop - target.frame.maxY - screen.frame.minY,
                                width: target.frame.width, height: target.frame.height)
        let windowFrame = try await engine.visibleRegion(windowRect, screen: screen, content: content, target: target)
        let windowHadAlpha = try await Task.detached {
            !(try ScrollFrameVisibility.matches(display: windowFrame, target: windowFrame))
        }.value
        let rounded = ScrollCapture()
        try await rounded.start(screen: screen, rect: windowRect, content: content, automatic: false)
        guard rounded.active, rounded.frames == 1 else { throw CaptureError.message("窗口圆角选区未提交首帧。") }
        await rounded.cancel()
        let ownHUD=NSWindow(contentRect:CGRect(x:world.minX+20,y:world.minY+20,width:40,height:80),
                            styleMask:[.borderless],backing:.buffered,defer:false)
        ownHUD.isReleasedWhenClosed=false;ownHUD.backgroundColor = .systemOrange;ownHUD.level = .floating
        ownHUD.orderFrontRegardless()
        defer { ownHUD.close() }
        _ = try await engine.visibleRegion(rect,screen:screen,content:content,target:target)
        ownHUD.close()
        try await model.start(screen:screen,rect:rect,content:content,automatic:false)
        let frames=model.frames,height=model.preview.height
        guard frames==1 else { throw CaptureError.message("无覆盖首帧未提交。") }
        try Data([1]).write(to:control,options:.atomic)
        for _ in 0..<60 where state()?["partialCover"] as? Bool != true { try await Task.sleep(for:.milliseconds(50)) }
        guard state()?["partialCover"] as? Bool == true else { throw CaptureError.message("自有部分遮挡未出现。") }
        for _ in 0..<100 where !model.paused { try await Task.sleep(for:.milliseconds(50)) }
        guard model.paused,DiagnosticScrollMessages.matches(model.warning, reason: .visibility),model.frames==frames,model.preview.height==height else {
            throw CaptureError.message("部分遮挡未暂停并保留原片段。")
        }
        try FileManager.default.removeItem(at:control)
        for _ in 0..<60 where state()?["partialCover"] as? Bool != false { try await Task.sleep(for:.milliseconds(50)) }
        model.togglePause()
        for _ in 0..<100 where model.warning != nil { try await Task.sleep(for:.milliseconds(50)) }
        guard model.active,!model.paused,model.warning==nil,model.frames==frames else { throw CaptureError.message("移除遮挡后未能恢复同一会话。") }
        await model.cancel()
        try Data([1]).write(to:control,options:.atomic)
        for _ in 0..<60 where state()?["partialCover"] as? Bool != true { try await Task.sleep(for:.milliseconds(50)) }
        let blocked=ScrollCapture()
        defer { Task { await blocked.cancel() } }
        var rejected=false
        do { try await blocked.start(screen:screen,rect:rect,content:content,automatic:false) }
        catch { rejected=DiagnosticScrollMessages.matches(error.localizedDescription, reason: .visibility) }
        guard rejected,!blocked.active,blocked.frames==0 else { throw CaptureError.message("首帧部分遮挡未在提交前拒绝。") }
        try? FileManager.default.removeItem(at:control)
        for _ in 0..<60 where state()?["partialCover"] as? Bool != false { try await Task.sleep(for: .milliseconds(50)) }
        // Exercise the real selection -> coordinator -> HUD entry point, using
        // only a generated target, temporary history and a private pasteboard.
        let board = NSPasteboard(name: .init("DeskCapture-scroll-entry-\(UUID())"))
        defer { board.releaseGlobally() }
        let app = AppCoordinator(store: CaptureStore(directory: root.appendingPathComponent("scroll-entry-history")), imagePasteboard: board, registerHotKeys: false)
        app.automaticScrolling = false
        app.scrollSelectionForDiagnostics = windowRect
        var confirmed = false
        app.onSelectionPresented = { confirmed = app.confirmScrollSelectionForDiagnostics() }
        defer { app.cancelCapture(); app.dashboard?.close() }
        for cycle in 0..<3 {
            confirmed = false
            application.activate(options: [])
            app.start(.scrolling)
            for _ in 0..<240 {
                if confirmed && !app.isCapturing { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard confirmed, app.scrollCapture.active, app.scrollCapture.frames == 1,
                  app.scrollOutlineVisibleForDiagnostics else {
                throw CaptureError.message("长图实际入口第\(cycle+1)次启动失败：\(app.notice ?? app.scrollCapture.warning ?? "未就绪")")
            }
            await app.cancelScrollCapture()
            guard !app.scrollCapture.active, !app.scrollOutlineVisibleForDiagnostics else {
                throw CaptureError.message("长图取消未清理会话和边框。")
            }
            // Subsequent selection must come from the retained product state.
            app.scrollSelectionForDiagnostics = nil
        }
        // A real native target with an intentionally unavailable AX container
        // inventory must still scroll at a window-verified point.
        let fallback = ScrollCapture(scanContainers: { _, _ in ScrollContainerScan(candidates: [], supported: false) })
        defer { Task { await fallback.cancel() } }
        application.activate(options: [])
        try await fallback.start(screen: screen, rect: rect, content: content, automatic: true)
        guard fallback.automatic, fallback.manualScrollPoint != nil else {
            throw CaptureError.message("未公开AX容器时自动滚动未启用。")
        }
        fallback.onDiagnosticAcceptedFrame = { _, count in count >= 2 }
        for _ in 0..<240 where fallback.frames < 2 { try await Task.sleep(for: .milliseconds(50)) }
        guard fallback.frames >= 2, fallback.paused else {
            throw CaptureError.message("选区滚动点未驱动真实页面：\(fallback.warning ?? "无滚动响应")")
        }
        let beforeResume = fallback.frames
        fallback.onDiagnosticAcceptedFrame = { _, count in count > beforeResume }
        fallback.togglePause()
        for _ in 0..<240 where fallback.frames <= beforeResume { try await Task.sleep(for: .milliseconds(50)) }
        guard fallback.frames > beforeResume else { throw CaptureError.message("自动滚动暂停恢复后未继续。") }
        await fallback.cancel()
        return ["roundedWindowSelectionStarted":true,"targetWindowHadTransparentEdges":windowHadAlpha,"fractionalSelectionExactPixels":true,"automaticWithoutAXContainer":true,"automaticResumeMovedContent":true,"fullRegionPixelComparison":true,"lateOwnHUDExcluded":true,"partialCoverPausedBeforeAppend":true,"sameSessionRecovered":true,
                "initialOcclusionRejected":true,"selectionHUDCancelReentryCycles":3,"persistentOutlineVerified":true,"generatedPixelsVerified":true,"preservedFrames":frames,
                "pixelSize":"\(verified.width)x\(verified.height)","rawDisplayImagesWritten":false]
    }

    nonisolated private static func difference(_ a:CGImage,_ b:CGImage) throws -> String {
        let width=a.width,height=a.height
        guard width==b.width,height==b.height else { return "尺寸不一致" }
        func context(_ image:CGImage) throws -> CGContext {
            guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw CaptureError.message("校准内存不足") }
            context.setBlendMode(.copy);context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return context
        }
        let ca=try context(a),cb=try context(b),pa=ca.data!.assumingMemoryBound(to:UInt8.self),pb=cb.data!.assumingMemoryBound(to:UInt8.self)
        var changed=0,alphaA=0,alphaB=0,total=0,minX=width,minY=height,maxX=0,maxY=0
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4
            if pa[i+3]<254 { alphaA += 1 };if pb[i+3]<254 { alphaB += 1 }
            let delta=(0..<3).map { abs(Int(pa[i+$0])-Int(pb[i+$0])) }
            total += delta.reduce(0,+)
            if delta.max()!>2 { changed += 1;minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y) }
        } }
        return "pixels=\(width)x\(height),changed=\(changed),alphaLow=\(alphaA)/\(alphaB),MAE=\(Double(total)/Double(width*height*3)),bounds=\(minX),\(minY),\(maxX),\(maxY)"
    }
}
