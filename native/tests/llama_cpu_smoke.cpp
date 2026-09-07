// Android release-runtime regression test. Link this executable against the
// APK's libjlexa_native.so and run with a Qwen2.5 Instruct GGUF path. It uses the
// same descriptor loader as SAF without modifying the model or app data.
#include "jlexa_llama_bridge.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fcntl.h>
#include <string>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc < 2 || argc > 3) {
        std::fprintf(stderr, "Usage: llama_cpu_smoke <Qwen2.5-Instruct.gguf> [cpu|vulkan]\n");
        return 2;
    }
    const int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        std::perror("open model");
        return 2;
    }

    JLexaLlamaRuntimeConfig config;
    config.backend = argc == 3 ? argv[2] : "cpu";
    if (config.backend != "cpu" && config.backend != "vulkan") {
        close(fd);
        return 2;
    }
    config.contextLength = 2048;
    config.batchSize = config.ubatchSize = 512;
    config.n_threads = 4;
    auto& bridge = JLexaLlamaBridge::instance();
    if (!bridge.loadModel("/proc/self/fd/" + std::to_string(fd), config)) {
        close(fd);
        return 3;
    }

    const auto active = bridge.getActiveBackendInfo();
    bool passed = active.backend == config.backend;
    std::printf("ACTIVE: %s / %s, batch=%d, ubatch=%d\n",
        active.backend.c_str(), active.deviceName.c_str(),
        active.batchSize, active.ubatchSize);
    const std::string prompts[] = {
        "What is 2 plus 2? Reply with only the number.",
        "Translate into Chinese: Good morning.",
        "Explain the difference between say and tell in two sentences.",
    };
    for (size_t index = 0; index < 3; ++index) {
        std::string answer;
        bool completed = false;
        bool failed = false;
        bridge.generate(prompts[index], 100, 0.0f, 0.9f, 1234,
            {{"system", "You are a helpful assistant. Answer clearly and concisely."},
             {"user", prompts[index]}},
            [&](const std::string& token) { answer += token; },
            [&](bool cancelled, const std::string& error) {
                completed = true;
                failed = cancelled || !error.empty();
                if (!error.empty()) std::fprintf(stderr, "%s\n", error.c_str());
            });
        std::printf("QUESTION: %s\nANSWER: %s\n", prompts[index].c_str(), answer.c_str());
        passed &= completed && !failed && !answer.empty();
        if (index == 0) {
            answer.erase(std::remove_if(answer.begin(), answer.end(),
                [](unsigned char ch) { return std::isspace(ch); }), answer.end());
            passed &= answer == "4";
        } else if (index == 1) {
            passed &= answer.find("早上好") != std::string::npos;
        }
        // The third answer is printed for review, not a semantic-quality score.
    }
    bridge.unloadModel();
    close(fd);
    std::printf("%s inference smoke test: %s\n", config.backend == "cpu" ? "CPU" : "Vulkan", passed ? "PASS" : "FAIL");
    return passed ? 0 : 1;
}
