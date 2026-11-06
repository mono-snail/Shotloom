import AppKit

/// SCK rounds a fractional source rectangle to whole points before fitting it
/// into the requested output size. An odd Retina pixel height can therefore
/// introduce a transparent column. Capture whole points at native scale first.
struct ScrollFrameRaster {
    let source: CGRect
    let width: Int
    let height: Int
    let crop: CGRect

    init(source requested: CGRect, scale: CGFloat) {
        let source = requested.integral
        self.source = source
        width = Int((source.width * scale).rounded())
        height = Int((source.height * scale).rounded())
        crop = CGRect(x: ((requested.minX - source.minX) * scale).rounded(),
                      y: ((requested.minY - source.minY) * scale).rounded(),
                      width: CGFloat(max(2, Int(requested.width * scale))),
                      height: CGFloat(max(2, Int(requested.height * scale))))
    }
}

/// No unverified display pixels leave this acquisition boundary. The second
/// image must be captured with a filter containing only the target window.
@MainActor
enum ScrollVisibleFrame {
    struct Obsolete: Error {}
    struct Occluded: Error { var reason: ScrollWindowVisibility.Failure = .covered }
    static func acquire(maxPairs: Int = 6, interval: Duration = .milliseconds(70),
                        transparentBorder: Int = 0,
                        onRejected: (@MainActor (String) -> Void)? = nil,
                        capture: @MainActor () async throws -> (display: CGImage, target: CGImage)) async throws -> CGImage {
        guard (1...12).contains(maxPairs) else { throw CaptureError.message(L10n.text("可见性检查预算无效。")) }
        var failure = L10n.text("目标窗口正文含透明区域，无法确认完整可见。请将选区放在不透明的正文区域；已有片段会保留。")
        for attempt in 0..<maxPairs {
            try Task.checkCancellation()
            let pair: (display: CGImage, target: CGImage)
            do { pair = try await capture() }
            catch let error as Occluded {
                failure = error.reason.message
                onRejected?("geometry")
                if attempt + 1 < maxPairs { try await Task.sleep(for: interval) }
                continue
            }
            try Task.checkCancellation()
            // Only a target-only acquisition may preserve transparent window
            // edges. A display/reference pair still requires opaque proof.
            let border = pair.display === pair.target ? transparentBorder : 0
            let worker=Task.detached(priority:.userInitiated) { try ScrollFrameVisibility.matches(display:pair.display,target:pair.target,transparentBorder:border) }
            let verified=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            try Task.checkCancellation()
            if verified { return pair.display }
            failure = pair.display === pair.target
                ? L10n.text("目标窗口正文含透明区域，无法确认完整可见。请将选区放在不透明的正文区域；已有片段会保留。")
                : L10n.text("目标画面与可见画面不一致，无法确认完整可见。请等待页面稳定或移开遮挡；已有片段会保留。")
            onRejected?(pair.display === pair.target ? "target-alpha" : "pixel-difference")
            if attempt+1<maxPairs { try await Task.sleep(for:interval) }
        }
        throw CaptureError.message(failure)
    }
}

enum ScrollFrameVisibility {
    /// Compare every pixel in bounded strips in the same color space. An opaque
    /// reference is required except for a bounded transparent target-only edge.
    /// Preserve those pixels rather than filling them with desktop/foreign data.
    static func matches(display: CGImage, target: CGImage, tolerance: Int = 2,
                        transparentBorder: Int = 0) throws -> Bool {
        try Task.checkCancellation()
        guard display.width==target.width,display.height==target.height,
              display.width>0,display.height>0,display.width<=60_000,display.height<=60_000,
              Double(display.width)*Double(display.height)<=80_000_000,(0...4).contains(tolerance),
              (0...64).contains(transparentBorder) else {
            throw CaptureError.message(L10n.text("可见性检查图像尺寸或预算不一致。"))
        }
        let width=display.width, height=display.height, band=max(1,min(128,4_000_000/(width*4)))
        // Always retain an opaque body, including for tiny selections.
        let border = min(transparentBorder, min(width, height) / 8)
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        for top in stride(from:0,to:height,by:band) {
            try Task.checkCancellation()
            let rows=min(band,height-top)
            let equal=try autoreleasepool { () throws -> Bool in
                let rect=CGRect(x:0,y:top,width:width,height:rows)
                guard let a=display.cropping(to:rect),let b=target.cropping(to:rect),
                      let ca=CGContext(data:nil,width:width,height:rows,bitsPerComponent:8,bytesPerRow:width*4,space:space,
                                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                      let cb=CGContext(data:nil,width:width,height:rows,bitsPerComponent:8,bytesPerRow:width*4,space:space,
                                      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw CaptureError.message(L10n.text("无法读取完整区域可见性像素。"))
                }
                ca.setBlendMode(.copy);cb.setBlendMode(.copy)
                ca.draw(a,in:CGRect(x:0,y:0,width:width,height:rows));cb.draw(b,in:CGRect(x:0,y:0,width:width,height:rows))
                let pa=ca.data!.assumingMemoryBound(to:UInt8.self),pb=cb.data!.assumingMemoryBound(to:UInt8.self)
                for y in 0..<rows {
                    if y % 32 == 0 { try Task.checkCancellation() }
                    for x in 0..<width {
                        let i=y*width*4+x*4
                        let edge = x < border || x >= width-border || top+y < border || top+y >= height-border
                        guard edge || (pa[i+3]>=254 && pb[i+3]>=254) else { return false }
                        for c in 0..<4 where abs(Int(pa[i+c])-Int(pb[i+c]))>tolerance { return false }
                    }
                }
                return true
            }
            if !equal { return false }
        }
        return true
    }
}


/// WindowServer geometry proves that no ordinary foreign window covers any
/// part of the selected rectangle. Pixels are acquired from the target only;
/// independent display and window screenshots are not a presentation fence.
enum ScrollWindowVisibility {
    enum Failure: Equatable {
        case outsideTarget, covered, targetUnavailable
        case coveredBy(String)
        var message: String {
            switch self {
            case .outsideTarget: return L10n.text("选区超出了目标窗口边界。请把整个长图选区放在同一个窗口内；已有片段会保留。")
            case .covered: return L10n.text("选区上方有其他窗口遮挡，无法确认完整可见。请移开遮挡后继续；已有片段会保留。")
            case .coveredBy(let application): return L10n.text("“\(application)”的窗口遮挡了长图选区，无法确认完整可见。请移开该窗口后继续；已有片段会保留。")
            case .targetUnavailable: return L10n.text("原目标窗口已隐藏或关闭。请恢复原窗口后继续；已有片段会保留。")
            }
        }
    }
    static func clear(region: CGRect, target: CGWindowID, ownPID: pid_t,
                      display: CGRect, windows: [[String: Any]],
                      bundlePath: (pid_t) -> String?) -> Bool {
        failure(region: region, target: target, ownPID: ownPID, display: display,
                windows: windows, bundlePath: bundlePath) == nil
    }
    static func failure(region: CGRect, target: CGWindowID, ownPID: pid_t,
                        display: CGRect, windows: [[String: Any]],
                        bundlePath: (pid_t) -> String?) -> Failure? {
        guard let item = windows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == target }),
              let raw = item[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return .targetUnavailable }
        guard region.width > 0, region.height > 0, bounds.contains(region) else { return .outsideTarget }
        for item in windows {
            guard (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { continue }
            let id = item[kCGWindowNumber as String] as? UInt32
            if id == target { return nil }
            guard bounds.intersection(region).width > 0, bounds.intersection(region).height > 0 else { continue }
            let pid = item[kCGWindowOwnerPID as String] as? Int32 ?? 0
            // showsCursor=false excludes the WindowServer cursor from our
            // target capture. Its geometric surface is not an obstruction.
            let windowName = item[kCGWindowName as String] as? String
            // WindowServer does not always publish a title for cursor surfaces.
            // Missing metadata must not turn the pointer into an obstruction.
            // Keep explicitly named non-cursor surfaces subject to the check.
            if item[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.cursorWindow)),
               item[kCGWindowOwnerName as String] as? String == "Window Server",
               windowName == nil || windowName == "" || windowName == "Cursor",
               bundlePath(pid) == nil { continue }
            if pid == ownPID { continue }
            // Dock has a display-sized input surface even when the Dock itself
            // is hidden. Never ignore an ordinary Dock-sized panel or other app.
            if item[kCGWindowLayer as String] as? Int == 20,
               bounds == display,
               bundlePath(pid) == "/System/Library/CoreServices/Dock.app" { continue }
            if let owner = item[kCGWindowOwnerName as String] as? String,
               !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .coveredBy(String(owner.prefix(60)))
            }
            return .covered
        }
        return .targetUnavailable
    }
}
