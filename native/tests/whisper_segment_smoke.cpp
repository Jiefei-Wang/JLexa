#include "jlexa_whisper_bridge.h"
#include "jlexa_llama_bridge.h"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <vector>
#include <cstdint>
#include <cstring>

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    // Register the same GPUs as the app to catch accidental Whisper GPU use.
    (void) JLexaLlamaBridge::instance();
    std::ifstream input(argv[2], std::ios::binary);
    char header[44];
    if (!input.read(header, sizeof(header)) || std::memcmp(header, "RIFF", 4) ||
        std::memcmp(header + 8, "WAVE", 4) || std::memcmp(header + 36, "data", 4)) return 2;
    uint32_t count;
    std::memcpy(&count, header + 40, 4);
    std::vector<int16_t> pcm(count / 2);
    if (!input.read(reinterpret_cast<char*>(pcm.data()), count)) return 2;
    std::vector<float> samples(pcm.size());
    for (size_t i = 0; i < pcm.size(); ++i) samples[i] = pcm[i] / 32768.0f;
    auto& bridge = JLexaWhisperBridge::instance();
    auto started = std::chrono::steady_clock::now();
    if (!bridge.loadModel(argv[1])) return 3;
    std::printf("WHISPER load_ms=%lld samples=%zu\n", static_cast<long long>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count()), samples.size());
    for (int run = 0; run < 2; ++run) {
        bridge.resetCancellation();
        started = std::chrono::steady_clock::now();
        const auto segments = bridge.transcribe(samples.data(), samples.size(), 4, "en", nullptr);
        std::printf("WHISPER run=%d inference_ms=%lld\n", run, static_cast<long long>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count()));
        if (!bridge.getLastError().empty() || segments.empty()) return 4;
        for (const auto& segment : segments) std::printf("TRANSCRIPT: %s\n", segment.text.c_str());
    }
    bridge.cancel();
    if (!bridge.transcribe(samples.data(), samples.size(), 4, "en", nullptr).empty()) return 5;
    bridge.resetCancellation();
    if (bridge.transcribe(samples.data(), samples.size(), 4, "en", nullptr).empty()) return 6;
    bridge.unloadModel();
    std::puts("Whisper segment smoke: PASS");
}
