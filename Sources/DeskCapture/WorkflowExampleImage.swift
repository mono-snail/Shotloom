import AppKit

/// An offline, bundled source for recipe configuration. It is not saved into
/// recipes or history; screenshot-triggered workflows receive the actual image.
enum WorkflowExampleImage {
    static func load() throws -> CGImage {
        try Task.checkCancellation()
#if SWIFT_PACKAGE
        let resources = Bundle.module
#else
        let resources = Bundle.main
#endif
        guard let url = resources.url(forResource: "WorkflowSample", withExtension: "png") else {
            throw CaptureError.message(L10n.text("内置流程示例图片缺失，请重新安装应用。"))
        }
        let image = try CaptureImageRead.load(url)
        try Task.checkCancellation()
        return image
    }
}
