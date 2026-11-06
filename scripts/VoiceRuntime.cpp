#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include "rnnoise.h"
#include "ebur128.h"

// Private protocol: native-endian Float32, interleaved stereo, 48 kHz.
// The Swift caller owns this temporary directory and commits no user file here.
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
struct Meter {
    ebur128_state *state = ebur128_init(2, 48000, EBUR128_MODE_I | EBUR128_MODE_TRUE_PEAK | EBUR128_MODE_HISTOGRAM);
    Meter() { require(state != nullptr, "meter allocation"); }
    ~Meter() { ebur128_destroy(&state); }
    void add(const float *data, size_t count) { require(ebur128_add_frames_float(state, data, count) == EBUR128_SUCCESS, "meter input"); }
    double lufs() { double result = NAN; require(ebur128_loudness_global(state, &result) == EBUR128_SUCCESS, "meter loudness"); return result; }
    double peak() { double result = 0; for (int c = 0; c < 2; ++c) { double value; require(ebur128_true_peak(state, c, &value) == EBUR128_SUCCESS, "meter peak"); result = std::max(result, value); } return result; }
};
static std::string number(double value) { return std::isfinite(value) ? std::to_string(value) : "null"; }
int main(int argc, char **argv) {
    if (argc != 9) return 2; // input output report wet normalize(0/1/measure) targetLUFS ceilingDBTP vad
    const std::string work = std::string(argv[2]) + ".work";
    try {
        const double wet = std::stod(argv[4]), target = std::stod(argv[6]), ceiling = std::stod(argv[7]);
        require(std::string(argv[5]) == "0" || std::string(argv[5]) == "1" || std::string(argv[5]) == "measure", "invalid mode");
        const bool normalize = std::string(argv[5]) == "1", vad = std::string(argv[8]) == "1";
        require(std::isfinite(wet) && wet >= 0 && wet <= 1 && std::isfinite(target) && target >= -30 && target <= -10 && std::isfinite(ceiling) && ceiling >= -6 && ceiling <= -1, "invalid parameters");
        std::ifstream input(argv[1], std::ios::binary | std::ios::ate);
        require(input.good(), "input open"); const auto bytes = input.tellg();
        require(bytes > 0 && bytes % 8 == 0 && bytes <= 3600LL * 48000 * 8, "input budget/format");
        const size_t frames = size_t(bytes) / 8; input.seekg(0);
        if (std::string(argv[5]) == "measure") {
            Meter meter; std::vector<float> chunk(8192);
            size_t readFrames = 0;
            while (input.read(reinterpret_cast<char *>(chunk.data()), chunk.size() * sizeof(float)) || input.gcount()) {
                const auto size = input.gcount(); require(size % 8 == 0, "measurement frame alignment");
                for (size_t i = 0; i < size_t(size) / sizeof(float); ++i) require(std::isfinite(chunk[i]) && std::abs(chunk[i]) <= 16, "measurement samples");
                meter.add(chunk.data(), size_t(size) / 8); readFrames += size_t(size) / 8;
            }
            require(input.eof() && readFrames == frames, "measurement read");
            const double lufs = meter.lufs();
            std::ofstream report(argv[3]); require(report.good(), "measurement report open");
            report << "{\"frames\":" << frames << ",\"sampleRate\":48000,\"inputLUFS\":" << number(lufs)
                   << ",\"outputLUFS\":" << number(lufs) << ",\"truePeak\":" << number(meter.peak())
                   << ",\"gainDB\":0,\"peakLimited\":false,\"vad\":[";
            for (size_t i = 0; i < (frames + 4799) / 4800; ++i) { if (i) report << ','; report << 0; }
            report << "]}"; report.close(); require(!report.fail(), "measurement report close"); return 0;
        }
        std::ofstream intermediate(work, std::ios::binary); require(intermediate.good(), "work open");
        const bool analyze = wet > 0 || vad;
        auto destroy = [](DenoiseState *value) { if (value) rnnoise_destroy(value); };
        std::unique_ptr<DenoiseState, decltype(destroy)> states[2] = {{analyze ? rnnoise_create(nullptr) : nullptr, destroy}, {analyze ? rnnoise_create(nullptr) : nullptr, destroy}};
        require(!analyze || (states[0] && states[1]), "model allocation");
        Meter original, enhanced;
        std::vector<float> probabilities((frames + 4799) / 4800, 0);
        float previous[960] = {}, current[960] = {}, output[960] = {}, channel[480], denoised[480];
        size_t previousCount = 0, written = 0;
        const size_t blocks = (frames + 479) / 480;
        for (size_t block = 0; block <= blocks; ++block) {
            std::fill(current, current + 960, 0);
            const size_t count = block < blocks ? std::min(size_t(480), frames - block * 480) : 0;
            if (count) {
                input.read(reinterpret_cast<char *>(current), count * 8); require(input.good(), "input read");
                for (size_t i = 0; i < count * 2; ++i) require(std::isfinite(current[i]) && std::abs(current[i]) <= 16, "non-finite input");
                original.add(current, count);
            }
            float probability = 0;
            if (analyze) {
                for (int c = 0; c < 2; ++c) {
                    for (int i = 0; i < 480; ++i) { require(std::isfinite(current[i * 2 + c]) && std::abs(current[i * 2 + c]) <= 16, "non-finite input"); channel[i] = std::clamp(current[i * 2 + c], -1.0f, 1.0f) * 32768; }
                    probability = std::max(probability, rnnoise_process_frame(states[c].get(), denoised, channel));
                    for (int i = 0; i < 480; ++i) output[i * 2 + c] = previous[i * 2 + c] * (1 - wet) + denoised[i] / 32768 * wet;
                }
            } else { std::copy(previous, previous + 960, output); }
            // RNNoise has one 480-sample frame of lookahead: skip its first
            // output, flush one padded frame, and retain the exact input length.
            if (block > 0 && previousCount) {
                for (size_t i = 0; i < previousCount * 2; ++i) require(std::isfinite(output[i]), "non-finite output");
                enhanced.add(output, previousCount);
                intermediate.write(reinterpret_cast<const char *>(output), previousCount * 8); require(intermediate.good(), "work write");
                probabilities[written / 4800] = std::max(probabilities[written / 4800], std::clamp(probability, 0.0f, 1.0f));
                written += previousCount;
            }
            std::copy(current, current + 960, previous); previousCount = count;
        }
        require(written == frames, "length mismatch"); intermediate.close(); require(!intermediate.fail(), "work close");
        const double inputLUFS = original.lufs(), processedLUFS = enhanced.lufs(), peak = enhanced.peak();
        double gain = normalize && std::isfinite(processedLUFS) ? std::min(16.0, std::pow(10.0, (target - processedLUFS) / 20)) : 1;
        const double requestedGain = gain;
        if ((wet > 0 || normalize) && peak > 0) gain = std::min(gain, std::pow(10.0, ceiling / 20) / peak);
        std::ifstream staged(work, std::ios::binary); std::ofstream destination(argv[2], std::ios::binary); require(staged.good() && destination.good(), "final open");
        Meter finalMeter; std::vector<float> chunk(8192);
        while (staged.read(reinterpret_cast<char *>(chunk.data()), chunk.size() * sizeof(float)) || staged.gcount()) {
            const auto size = staged.gcount(); require(size % 8 == 0, "final frame alignment");
            for (size_t i = 0; i < size_t(size) / sizeof(float); ++i) chunk[i] *= gain;
            finalMeter.add(chunk.data(), size_t(size) / 8); destination.write(reinterpret_cast<char *>(chunk.data()), size); require(destination.good(), "final write");
        }
        require(staged.eof(), "final read"); destination.close(); require(!destination.fail(), "final close");
        std::ofstream report(argv[3]); require(report.good(), "report open");
        report << "{\"frames\":" << frames << ",\"sampleRate\":48000,\"inputLUFS\":" << number(inputLUFS)
               << ",\"outputLUFS\":" << number(finalMeter.lufs()) << ",\"truePeak\":" << number(finalMeter.peak())
               << ",\"gainDB\":" << number(20 * std::log10(gain)) << ",\"peakLimited\":" << (gain < requestedGain ? "true" : "false") << ",\"vad\":[";
        for (size_t i = 0; i < probabilities.size(); ++i) { if (i) report << ','; report << probabilities[i]; } report << "]}";
        report.close(); require(!report.fail(), "report close"); std::remove(work.c_str()); return 0;
    } catch (const std::exception &error) { std::fprintf(stderr, "voice processing failed: %s\n", error.what()); std::remove(work.c_str()); return 1; }
}
