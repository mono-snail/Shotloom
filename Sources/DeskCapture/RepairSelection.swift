import AppKit

struct RepairStroke: Codable, Equatable, Identifiable {
    var id = UUID()
    var points: [CGPoint] // normalized, top-left origin
    var diameter: CGFloat = 40
    var erase = false
}
struct RepairSelection: Equatable {
    var strokes: [RepairStroke] = []
    var feather: CGFloat = 4
    func raster(width: Int, height: Int) throws -> RepairRasterMask {
        guard width > 0, height > 0, Double(width)*Double(height) <= 16_000_000,
              strokes.count <= 256, strokes.reduce(0, { $0+$1.points.count }) <= 8192,
              feather.isFinite, (0...32).contains(feather) else { throw CaptureError.message(L10n.text("选区超过1600万像素或笔画预算，请分区处理。")) }
        var values = [UInt8](repeating: 0, count: width*height), work = 0
        for stroke in strokes {
            try Task.checkCancellation()
            guard stroke.diameter.isFinite, (1...400).contains(stroke.diameter), !stroke.points.isEmpty,
                  stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                throw CaptureError.message(L10n.text("笔画范围无效。"))
            }
            let points = stroke.points.map { CGPoint(x: $0.x*CGFloat(width), y: $0.y*CGFloat(height)) }
            for i in 0..<max(1,points.count-1) {
                let a=points[i],b=points[min(i+1,points.count-1)], radius=stroke.diameter/2
                let x0=max(0,Int(floor(min(a.x,b.x)-radius))),x1=min(width-1,Int(ceil(max(a.x,b.x)+radius)))
                let y0=max(0,Int(floor(min(a.y,b.y)-radius))),y1=min(height-1,Int(ceil(max(a.y,b.y)+radius)))
                guard x1>=x0,y1>=y0 else { continue }
                work += (x1-x0+1)*(y1-y0+1)
                guard work <= 64_000_000 else { throw CaptureError.message(L10n.text("笔画计算超过预算，请减少笔画或分次处理。")) }
                let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
                for y in y0...y1 {
                    if y % 32 == 0 { try Task.checkCancellation() }
                    for x in x0...x1 {
                        let px=CGFloat(x)+0.5,py=CGFloat(y)+0.5
                        let t=length>0 ? max(0,min(1,((px-a.x)*dx+(py-a.y)*dy)/length)) : 0
                        let distance=hypot(px-a.x-t*dx,py-a.y-t*dy)
                        guard distance<radius else { continue }
                        let blend=feather>0 ? max(0,min(1,(radius-distance)/min(feather,radius))) : 1
                        let alpha=Int((blend*255).rounded()), index=y*width+x, old=Int(values[index])
                        values[index]=UInt8(stroke.erase ? old*(255-alpha)/255 : max(old,alpha))
                    }
                }
            }
        }
        return .init(width: width,height: height,values: values)
    }
}
struct RepairRasterMask: Sendable {
    let width: Int
    let height: Int
    let values: [UInt8]
    var bounds: CGRect? {
        var x0=width,y0=height,x1 = -1,y1 = -1
        for y in 0..<height { for x in 0..<width where values[y*width+x]>0 { x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y) } }
        return x1>=x0 && y1>=y0 ? CGRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1) : nil
    }
    var image: CGImage? {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),
                provider:CGDataProvider(data:Data(values) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}

enum RepairPixelComposite {
    /// Clones the original provider bytes. Pixels with zero mask weight are never
    /// rewritten, including their alpha and padding bytes; the color space stays intact.
    static func apply(base: CGImage, patch: CGImage, rect: CGRect, mask: RepairRasterMask) throws -> CGImage {
        guard base.width == mask.width, base.height == mask.height, mask.values.count == mask.width*mask.height, base.bitsPerComponent == 8, base.bitsPerPixel == 32,
              base.colorSpace?.model == .rgb, base.decode == nil, !base.bitmapInfo.contains(.floatComponents),
              let space=base.colorSpace,let provider=base.dataProvider,let source=provider.data,
              Double(base.bytesPerRow)*Double(base.height)<=100_000_000 else {
            throw CaptureError.message(L10n.text("此图片像素格式暂不支持精确保留选区外内容，请先另存为8位PNG。"))
        }
        let area=rect.integral.intersection(CGRect(x:0,y:0,width:base.width,height:base.height))
        guard !area.isEmpty,area==rect.integral,area.width*area.height<=16_000_000 else { throw CaptureError.message(L10n.text("修补区域无效或超出预算。")) }
        let w=Int(area.width),h=Int(area.height)
        let straightAlpha = base.alphaInfo == .first || base.alphaInfo == .last
        let patchAlpha: CGImageAlphaInfo = base.alphaInfo == .first ? .premultipliedFirst : .premultipliedLast
        let patchInfo = straightAlpha ? (base.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | patchAlpha.rawValue : base.bitmapInfo.rawValue
        let alphaIndex = base.alphaInfo == .first ? (base.bitmapInfo.contains(.byteOrder32Little) ? 3 : 0) : (base.bitmapInfo.contains(.byteOrder32Little) ? 0 : 3)
        guard let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:space,bitmapInfo:patchInfo) else {
            throw CaptureError.message(L10n.text("无法生成修补像素。"))
        }
        context.interpolationQuality = .high;context.setBlendMode(.copy)
        context.draw(patch,in:CGRect(x:0,y:0,width:w,height:h))
        let replacement=context.data!.assumingMemoryBound(to:UInt8.self)
        var bytes=Data(source as Data)
        guard bytes.count>=base.bytesPerRow*base.height else { throw CaptureError.message(L10n.text("图片像素数据不完整。")) }
        try bytes.withUnsafeMutableBytes { raw in
            let output=raw.bindMemory(to:UInt8.self)
            for y in 0..<h {
                if y % 32 == 0 { try Task.checkCancellation() }
                for x in 0..<w {
                    let gx=Int(area.minX)+x,gy=Int(area.minY)+y,alpha=Int(mask.values[gy*base.width+gx])
                    guard alpha>0 else { continue }
                    if straightAlpha {
                        let dst=gy*base.bytesPerRow+gx*4,src=y*context.bytesPerRow+x*4
                        let oldAlpha=Int(output[dst+alphaIndex]),newAlpha=Int(replacement[src+alphaIndex])
                        let denominator=oldAlpha*(255-alpha)+newAlpha*alpha
                        for c in 0..<4 where c != alphaIndex {
                            let numerator=Int(output[dst+c])*oldAlpha*(255-alpha)+Int(replacement[src+c])*255*alpha
                            output[dst+c]=UInt8(denominator>0 ? min(255,(numerator+denominator/2)/denominator) : 0)
                        }
                        output[dst+alphaIndex]=UInt8((denominator+127)/255)
                        continue
                    }
                    for c in 0..<4 {
                        let dst=gy*base.bytesPerRow+gx*4+c,src=y*context.bytesPerRow+x*4+c
                        output[dst]=UInt8((Int(output[dst])*(255-alpha)+Int(replacement[src])*alpha+127)/255)
                    }
                }
            }
        }
        guard let result=CGImage(width:base.width,height:base.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:base.bytesPerRow,
            space:space,bitmapInfo:base.bitmapInfo,provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:base.shouldInterpolate,intent:base.renderingIntent) else {
            throw CaptureError.message(L10n.text("无法创建修补结果。"))
        }
        return result
    }
}

enum LocalRepairMethod: String, CaseIterable, Identifiable {
    case texture, smooth, clone, model, restore, transparent
    var id: String { rawValue }
    var title: String { switch self { case .texture: L10n.text("纹理修补"); case .smooth: L10n.text("平滑修补"); case .clone: L10n.text("取样修补"); case .model: L10n.text("离线模型"); case .restore: L10n.text("恢复原像素"); case .transparent: L10n.text("擦除背景") } }
}
enum RepairModelContext: String, CaseIterable, Identifiable {
    case nearby, expanded
    var id: String { rawValue }
    var title: String { self == .nearby ? L10n.text("邻近背景") : L10n.text("扩大背景") }

    func region(for selection: CGRect, imageSize: CGSize) throws -> CGRect {
        let image = CGRect(origin: .zero, size: imageSize)
        guard [selection.minX, selection.minY, selection.width, selection.height,
               imageSize.width, imageSize.height].allSatisfy(\.isFinite),
              selection.width > 0, selection.height > 0,
              imageSize.width >= 1, imageSize.height >= 1,
              imageSize.width.rounded() == imageSize.width, imageSize.height.rounded() == imageSize.height,
              imageSize.width * imageSize.height <= 16_000_000,
              image.contains(selection) else {
            throw CaptureError.message(L10n.text("模型参考区域无效或超过像素预算。"))
        }
        let margin = max(24, max(selection.width, selection.height) * (self == .nearby ? 0.25 : 1.5))
        return selection.insetBy(dx: -margin, dy: -margin).integral.intersection(image)
    }
}
enum LocalImageRepair {
    static func render(base: CGImage, original: CGImage, selection: RepairSelection, method: LocalRepairMethod,
                       anchor: CGPoint?, modelID: UUID?, library: RepairModelLibrary = .shared,
                       modelContext: RepairModelContext = .nearby, blendBoundaryColors: Bool = false) async throws -> CGImage {
        try await renderWithMask(base:base,original:original,selection:selection,method:method,anchor:anchor,
                                 modelID:modelID,library:library,modelContext:modelContext,blendBoundaryColors:blendBoundaryColors).image
    }
    struct Result: Sendable { let image: CGImage; let mask: RepairRasterMask }
    static func renderWithMask(base: CGImage, original: CGImage, selection: RepairSelection, method: LocalRepairMethod,
                              anchor: CGPoint?, modelID: UUID?, library: RepairModelLibrary = .shared,
                              modelContext: RepairModelContext = .nearby, blendBoundaryColors: Bool = false) async throws -> Result {
        try Task.checkCancellation()
        let worker=Task.detached(priority:.userInitiated) { try selection.raster(width:base.width,height:base.height) }
        let mask=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        try Task.checkCancellation()
        guard let bounds=mask.bounds else { throw CaptureError.message(L10n.text("请先涂画要处理的选区。")) }
        var rect=bounds; let patch:CGImage
        if method == .transparent {
            let task=Task.detached(priority:.userInitiated) { () throws -> CGImage in
                try RepairTransparency.apply(base:base,mask:mask)
            }
            let output=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            try Task.checkCancellation();return .init(image:output,mask:mask)
        }
        if method == .model {
            guard let id=modelID,let maskImage=mask.image else { throw CaptureError.message(L10n.text("请先导入并选择兼容的本地模型，或使用纹理修补。")) }
            rect=try modelContext.region(for:bounds,imageSize:CGSize(width:base.width,height:base.height))
            guard let context=base.cropping(to:rect),let croppedMask=maskImage.cropping(to:rect) else { throw CaptureError.message(L10n.text("无法读取模型修补区域。")) }
            patch=try await library.infer(image:context,mask:croppedMask,using:id)
        } else if method == .restore {
            guard original.width==base.width,original.height==base.height,let restored=original.cropping(to:rect) else { throw CaptureError.message(L10n.text("原图尺寸与当前结果不一致。")) }
            patch=restored
        } else {
            let a=CGPoint(x:bounds.minX/CGFloat(base.width),y:1-bounds.maxY/CGFloat(base.height))
            let b=CGPoint(x:bounds.maxX/CGFloat(base.width),y:1-bounds.minY/CGFloat(base.height))
            if method == .clone && anchor == nil { throw CaptureError.message(L10n.text("请先设置取样点。")) }
            let snapshotRect=rect
            let task=Task.detached(priority:.userInitiated) { () throws -> CGImage in
                let value=method == .smooth ? CaptureRepair.patch(base,normalized:a,b)
                    : CaptureRepair.texturePatch(base,normalized:a,b,anchor:method == .clone ? anchor.map{CGPoint(x:$0.x,y:1-$0.y)}:nil)
                guard let value, snapshotRect.width>0 else { throw CaptureError.message(L10n.text("修补失败，请换一个取样区域。")) };return value
            }
            patch=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        }
        try Task.checkCancellation()
        let outputRect=rect
        let compositing=Task.detached(priority:.userInitiated) {
            let output = try RepairPixelComposite.apply(base:base,patch:patch,rect:outputRect,mask:mask)
            if method == .texture && blendBoundaryColors {
                return try RepairBoundaryBlend.apply(base:base,repaired:output,mask:mask)
            }
            return output
        }
        let output=try await withTaskCancellationHandler(operation:{try await compositing.value},onCancel:{compositing.cancel()})
        try Task.checkCancellation();return .init(image:output,mask:mask)
    }
}
