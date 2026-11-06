import Accelerate

// Streaming overlap-add Wiener suppression. No audio is sent off-device.
final class SpectralNoiseReducer {
    static let hop = 256
    private let n = 512
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    private var previous: [[Float]]
    private var overlap: [[Float]]
    private var noise: [[Float]]
    private var gains: [[Float]]
    private let window: [Float]
    private let strength: Float
    init(channels: Int, strength: Float) throws {
        guard let f = vDSP_DFT_zop_CreateSetup(nil, 512, .FORWARD), let i = vDSP_DFT_zop_CreateSetup(nil, 512, .INVERSE) else { throw CaptureError.message(L10n.text("无法初始化频谱降噪。")) }
        forward = f; inverse = i; self.strength = min(1, max(0, strength))
        previous = Array(repeating: Array(repeating: 0, count: 256), count: channels)
        overlap = previous
        noise = Array(repeating: Array(repeating: 0.000001, count: 512), count: channels)
        gains = Array(repeating: Array(repeating: 1, count: 512), count: channels)
        window = (0..<512).map { sin(Float.pi * (Float($0) + 0.5) / 512) }
    }
    deinit { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }
    func process(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        for channel in previous.indices {
            for offset in stride(from: 0, to: frames, by: Self.hop) {
                var real = [Float](repeating: 0, count: n), imaginary = real, re = real, im = real, out = real, outI = real
                let input = Array(UnsafeBufferPointer(start: channels[channel] + offset, count: Self.hop))
                for i in 0..<Self.hop { real[i] = previous[channel][i] * window[i]; real[i + Self.hop] = input[i] * window[i + Self.hop] }
                let rms = sqrt(input.reduce(0) { $0 + $1 * $1 } / Float(Self.hop))
                vDSP_DFT_Execute(forward, real, imaginary, &re, &im)
                for bin in 0..<n {
                    let power = re[bin] * re[bin] + im[bin] * im[bin]
                    if rms < 0.012 { noise[channel][bin] = noise[channel][bin] * 0.90 + power * 0.10 }
                    else { noise[channel][bin] = min(power, noise[channel][bin] * 1.0005 + 0.000001) }
                    let target = max(0.12, 1 - strength * noise[channel][bin] / max(0.000001, power))
                    gains[channel][bin] = gains[channel][bin] * 0.65 + target * 0.35
                    re[bin] *= gains[channel][bin]; im[bin] *= gains[channel][bin]
                }
                vDSP_DFT_Execute(inverse, re, im, &out, &outI)
                for i in 0..<Self.hop {
                    channels[channel][offset + i] = out[i] / Float(n) * window[i] + overlap[channel][i]
                    overlap[channel][i] = out[i + Self.hop] / Float(n) * window[i + Self.hop]
                }
                previous[channel] = input
            }
        }
    }
}
