import AppKit

enum ClipboardImageEncoding {
    struct Payload { let png: Data; let tiff: Data? }

    static func run(_ operation: @escaping @Sendable () throws -> Payload) async throws -> Payload {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try await ClipboardEncodingWorker.shared.run(operation)
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                let value = try await worker.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }, onCancel: { worker.cancel() })
    }

    static func encode(_ source: CGImage, logicalSize: Bool, backingScale: CGFloat) async throws -> Payload {
        try await encode(logicalSize: logicalSize, backingScale: backingScale, loadImage: { source })
    }

    /// Reading a history image is part of the same cancellable background job as
    /// encoding, so the clipboard revision is captured before any file work.
    static func encode(logicalSize: Bool, backingScale: CGFloat,
                       loadImage: @escaping @Sendable () throws -> CGImage) async throws -> Payload {
        try await run {
            let source = try loadImage()
            try Task.checkCancellation()
            let image = try CapturePreferences.clipboardImage(source, logicalSize: logicalSize, backingScale: backingScale)
            try Task.checkCancellation()
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.message(L10n.text("图片编码失败。")) }
            try Task.checkCancellation()
            let tiff = image.width * image.height <= 8_000_000 ? bitmap.tiffRepresentation : nil
            try Task.checkCancellation()
            return Payload(png: png, tiff: tiff)
        }
    }
}

// Native encoders cannot be interrupted in the middle of a call. Serializing
// admission prevents rapid Copy requests from starting unbounded large encodes;
// cancelled queued requests are rejected before touching their source.
private actor ClipboardEncodingWorker {
    static let shared = ClipboardEncodingWorker()
    func run(_ operation: @Sendable () throws -> ClipboardImageEncoding.Payload) throws -> ClipboardImageEncoding.Payload {
        try Task.checkCancellation()
        let result = try autoreleasepool { try operation() }
        try Task.checkCancellation()
        return result
    }
}

actor HistoryImageLoader {
    func load(_ url: URL, using read: @Sendable (URL) throws -> CGImage) throws -> CGImage {
        try Task.checkCancellation()
        let result = try autoreleasepool { try read(url) }
        try Task.checkCancellation()
        return result
    }
}
