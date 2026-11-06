import AppKit
import CoreImage
import Vision

/// One immutable source and one instance namespace. Actor isolation serializes
/// native mask generation, including a cancelled call that has not returned yet.
actor ForegroundSubjectAnalysis {
    private let source: CGImage
    private var analysis: (VNImageRequestHandler, VNInstanceMaskObservation)?
    private var previews: [ForegroundSubject]?
    private(set) var diagnosticInferenceCount = 0
    init(source: CGImage) { self.source=source }

    private func observation() throws -> (VNImageRequestHandler, VNInstanceMaskObservation) {
        try Task.checkCancellation()
        if let analysis { return analysis }
        guard Double(source.width)*Double(source.height)<=20_000_000 else { throw CaptureError.message(L10n.text("主体分析最多支持2000万像素。")) }
        let handler=VNImageRequestHandler(cgImage:source,options:[:]), request=VNGenerateForegroundInstanceMaskRequest()
        diagnosticInferenceCount += 1
        try handler.perform([request]);try Task.checkCancellation()
        guard let result=request.results?.first,!result.allInstances.isEmpty else { throw CaptureError.message(L10n.text("没有识别到明确主体，可使用画笔手工修正。")) }
        analysis=(handler,result)
        return (handler,result)
    }
    func subjects() throws -> [ForegroundSubject] {
        try Task.checkCancellation()
        if let previews { return previews }
        let (handler,result)=try observation()
        let output=try CaptureImageCleanup.subjectPreviews(handler:handler,observation:result)
        try Task.checkCancellation();previews=output
        return output
    }
    func erasure(instances: IndexSet? = nil) throws -> RepairRasterMask {
        let (handler,result)=try observation(), chosen=instances ?? result.allInstances
        guard !chosen.isEmpty,chosen.isSubset(of:result.allInstances) else { throw CaptureError.message(L10n.text("所选主体不在当前图片中，请重新识别。")) }
        let buffer=try result.generateScaledMaskForImage(forInstances:chosen,from:handler)
        try Task.checkCancellation()
        return try ForegroundMaskPixels.erasure(buffer,width:source.width,height:source.height)
    }
}
