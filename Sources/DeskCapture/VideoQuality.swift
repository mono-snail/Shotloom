import Foundation
import CoreImage
import SwiftUI

struct VideoQualityOptions: Codable, Equatable {
    var deband = false
    var strength = 0.5
    var threshold = 0.018
    var radius = 1.0
    var dither = 0.3
    var sharpen = false
    var detail = 0.25
    var memoryMiB = 1024
    var active: Bool { (deband && strength > 0) || (sharpen && detail > 0) }
    func validate() throws {
        guard [strength, threshold, radius, dither, detail].allSatisfy(\.isFinite),
              (0...1).contains(strength), (0.004...0.05).contains(threshold), (1...3).contains(radius),
              (0...0.75).contains(dither), (0...0.75).contains(detail), (256...2048).contains(memoryMiB) else { throw CaptureError.message(L10n.text("视频画质或内存预算参数无效。")) }
    }
    func estimatedMiB(source: CGSize, output: CGSize, opticalSamples: Int) throws -> Int {
        try validate()
        guard [source.width, source.height, output.width, output.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16384 }),
              source.width * source.height <= 67_108_864, output.width * output.height <= 16_777_216 else { throw CaptureError.message(L10n.text("视频源尺寸超过处理预算。")) }
        let sourceBytes = source.width * source.height * 8 * 2
        let outputBytes = output.width * output.height * 8 * Double(3 + (active ? 2 : 0) + min(49, max(0, opticalSamples)))
        let estimate = Int(ceil((sourceBytes + outputBytes) / 1_048_576)) + 128
        guard estimate <= memoryMiB else { throw CaptureError.message(L10n.text("估算画面工作集\(estimate)MiB超过\(memoryMiB)MiB预算；请降低输出尺寸/模糊采样或调整预算。此预算不是进程RSS硬上限。")) }
        return estimate
    }
}

// Kernel/options are immutable; the only mutable fields are metrics protected
// by lock. CIKernel supports concurrent application to independent frames.
final class VideoQualityFilter: @unchecked Sendable {
    let options: VideoQualityOptions
    private let kernel: CIKernel?
    private let lock = NSLock()
    private var frames = 0
    private var graphSeconds = 0.0
    init(options: VideoQualityOptions) throws {
        try options.validate(); self.options = options
        kernel = options.active ? try CIKernel.kernels(withMetalString: Self.source).first : nil
        if options.active && kernel == nil { throw CaptureError.message(L10n.text("当前系统未能准备画质处理内核；请关闭增强后导出。")) }
    }
    func apply(_ image: CIImage) throws -> CIImage {
        guard options.active, let kernel else { return image }
        let started = ProcessInfo.processInfo.systemUptime
        defer { lock.lock(); frames += 1; graphSeconds += ProcessInfo.processInfo.systemUptime - started; lock.unlock() }
        let extent = image.extent, radius = options.radius
        guard let output = kernel.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -radius - 1, dy: -radius - 1) }, arguments: [
            image.clampedToExtent(), options.deband ? options.strength : 0, options.threshold, radius,
            options.sharpen ? options.detail : 0, options.deband ? options.dither : 0]) else { throw CaptureError.message(L10n.text("画质处理无法生成当前帧。")) }
        return output.cropped(to: extent)
    }
    static func isHDR(_ transfer: String?) -> Bool {
        transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }
    func report(exportSeconds: Double, estimatedMiB: Int) async {
        guard let path = ProcessInfo.processInfo.environment["DESKCAPTURE_PERFORMANCE_REPORT_DIR"] else { return }
        let values: (Int, Double) = { lock.lock(); defer { lock.unlock() }; return (frames, graphSeconds) }()
        let options = options
        await Task.detached(priority: .utility) {
            struct Report: Encodable {
                let kind = "R40-quality"
                let frames: Int; let graphBuildCPUSeconds: Double; let fullExportWallSeconds: Double
                let estimatedWorkingSetMiB: Int; let requestedBudgetMiB: Int; let options: VideoQualityOptions
                let scope = "Working-set estimate and CI graph construction only; neither is measured process/GPU memory or GPU execution time. Compare paired exports and sample actual RSS."
            }
            do {
                let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let value = Report(frames: values.0, graphBuildCPUSeconds: values.1, fullExportWallSeconds: exportSeconds, estimatedWorkingSetMiB: estimatedMiB, requestedBudgetMiB: options.memoryMiB, options: options)
                try JSONEncoder().encode(value).write(to: root.appendingPathComponent("r40-quality-\(UUID()).json"), options: .atomic)
            } catch { NSLog("DeskCapture quality measurement unavailable: %@", error.localizedDescription) }
        }.value
    }
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    [[stitchable]] float4 desk_quality(sampler image, float strength, float threshold, float radius, float detail, float dither, destination dest) {
        float2 p = dest.coord();
        float4 c = unpremultiply(image.sample(image.transform(p)));
        float4 n = unpremultiply(image.sample(image.transform(p + float2(0.0, radius))));
        float4 s = unpremultiply(image.sample(image.transform(p - float2(0.0, radius))));
        float4 e = unpremultiply(image.sample(image.transform(p + float2(radius, 0.0))));
        float4 w = unpremultiply(image.sample(image.transform(p - float2(radius, 0.0))));
        float3 dn = abs(n.rgb-c.rgb), ds = abs(s.rgb-c.rgb), de = abs(e.rgb-c.rgb), dw = abs(w.rgb-c.rgb);
        float4 delta = float4(max(dn.r,max(dn.g,dn.b)),max(ds.r,max(ds.g,ds.b)),max(de.r,max(de.g,de.b)),max(dw.r,max(dw.g,dw.b)));
        float4 alpha = step(abs(float4(n.a,s.a,e.a,w.a)-float4(c.a)),float4(0.001));
        float4 weights = (float4(1.0)-smoothstep(float4(threshold*0.5),float4(threshold),delta))*alpha;
        float3 mean = (4.0*c.rgb+n.rgb*weights.x+s.rgb*weights.y+e.rgb*weights.z+w.rgb*weights.w)/(4.0+dot(weights,float4(1.0)));
        float edge = max(max(delta.x,delta.y),max(delta.z,delta.w));
        float flat = (1.0-smoothstep(threshold,threshold*2.0,edge))*alpha.x*alpha.y*alpha.z*alpha.w;
        float3 rgb = mix(c.rgb,mean,strength*flat);
        float3 low = min(c.rgb,min(min(n.rgb,s.rgb),min(e.rgb,w.rgb)));
        float3 high = max(c.rgb,max(max(n.rgb,s.rgb),max(e.rgb,w.rgb)));
        float luminanceDetail = dot(c.rgb-(n.rgb+s.rgb+e.rgb+w.rgb)*0.25,float3(0.2126,0.7152,0.0722));
        rgb = clamp(rgb+float3(luminanceDetail*detail),low,high);
        float a = fract(sin(dot(p,float2(12.9898,78.233)))*43758.5453);
        float b = fract(sin(dot(p,float2(39.3468,11.1351)))*24634.6345);
        rgb += float3((a-b)*dither*strength*flat/255.0);
        return float4(clamp(rgb,0.0,1.0)*c.a,c.a);
    }
    }}
    """
}

struct VideoQualityEditor: View {
    @Binding var options: VideoQualityOptions
    var initiallyExpanded = false
    private let budgets = [256, 512, 1024, 1536, 2048]
    var body: some View {
        VideoInspectorGroup(L10n.text("画质"), initiallyExpanded: initiallyExpanded, grid: false) {
            VideoControlGrid {
            Toggle(L10n.text("平滑渐变"), isOn: $options.deband)
            if options.deband {
                InspectorSlider(title: L10n.text("平滑强度"), value: $options.strength, range: 0...1, scale: 100, unit: "%")
            }
            Toggle(L10n.text("锐化"), isOn: $options.sharpen)
            if options.sharpen {
                InspectorSlider(title: L10n.text("锐化强度"), value: $options.detail, range: 0...0.75, scale: 100, unit: "%")
            }
            // The processing guard also applies with both enhancement filters
            // off. Keep its recovery control available independently of them.
            VideoField(title: L10n.text("内存预算")) {
                Picker(L10n.text("内存预算"), selection: $options.memoryMiB) {
                    ForEach(budgets, id: \.self) { Text("\($0) MiB").tag($0) }
                    if (256...2048).contains(options.memoryMiB), !budgets.contains(options.memoryMiB) {
                        Text("\(options.memoryMiB) MiB").tag(options.memoryMiB)
                    }
                }.pickerStyle(.menu)
            }
            }
            if options.deband {
                DisclosureGroup(L10n.text("平滑参数")) {
                    VideoControlGrid {
                        InspectorSlider(title: L10n.text("边缘阈值"), value: $options.threshold, range: 0.004...0.05, decimals: 3)
                        InspectorSlider(title: L10n.text("采样半径"), value: $options.radius, range: 1...3, unit: " px", decimals: 1)
                        InspectorSlider(title: L10n.text("抖动强度"), value: $options.dither, range: 0...0.75, decimals: 2)
                    }.padding(.top, 12)
                }
            }
        }
    }
}
