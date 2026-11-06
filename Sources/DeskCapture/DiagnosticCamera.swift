import AVFoundation

enum DiagnosticCamera {
    struct Identity: Sendable {
        let id: String
        let name: String
        let type: String
        var report: [String: String] { ["id": id, "name": name, "type": type] }
    }
    static func resolve(explicitID: String? = nil) async throws -> Identity {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let device: AVCaptureDevice?
            if let explicitID { device = AVCaptureDevice(uniqueID: explicitID) }
            else {
                device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices.first
            }
            guard let device, device.isConnected else { throw CaptureError.message("诊断指定的摄像头不可用，未换用其他设备。") }
            return Identity(id: device.uniqueID, name: device.localizedName, type: device.deviceType.rawValue)
        }.value
    }
}
