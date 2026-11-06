import AVFoundation

struct RecordingAudioSource: Identifiable, Sendable {
    let id: Int
    let title: String

    /// Do not infer microphone/system roles from channels or track order in an
    /// imported or older recording. Only our explicit track title certifies it.
    static func inspect(_ url: URL) async throws -> [Self] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let roles = RecordingInteractions.load(url)?.audioSources
        var sources: [Self] = []
        for (index, track) in tracks.prefix(128).enumerated() {
            try Task.checkCancellation()
            var title = tracks.count == 1 ? L10n.text("原片声音") : L10n.text("音轨 \(index + 1)")
            if let roles, roles.count == tracks.count {
                if roles[index] == "system" { title = L10n.text("系统声音") }
                if roles[index] == "microphone" { title = L10n.text("麦克风") }
            }
            for item in (try? await track.load(.metadata)) ?? [] where item.commonKey == .commonKeyTitle {
                let value = try? await item.load(.stringValue)
                if value == "DeskCapture System Audio" { title = L10n.text("系统声音"); break }
                if value == "DeskCapture Microphone" { title = L10n.text("麦克风"); break }
            }
            sources.append(Self(id: index, title: title))
        }
        return sources
    }
}
