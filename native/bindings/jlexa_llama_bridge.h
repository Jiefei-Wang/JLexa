#ifndef JLEXA_LLAMA_BRIDGE_H
#define JLEXA_LLAMA_BRIDGE_H

#include <string>
#include <vector>
#include <functional>
#include <cstdint>

#include "../plugin/jlexa_inference_types.h"
#include "../plugin/jlexa_benchmark.h"

class JLexaLlamaBridge {
public:
    static JLexaLlamaBridge& instance();

    std::vector<JLexaBackendInfo> getAvailableBackends();
    JLexaActiveBackendInfo getActiveBackendInfo();

    bool loadModel(const std::string& modelPath, const JLexaLlamaRuntimeConfig& config);
    bool loadModel(const std::string& modelPath, int contextLength = 2048, int n_threads = 4);
    void unloadModel();
    bool isModelLoaded();

    void generate(
        const std::string& prompt,
        int maxTokens,
        float temperature,
        float topP,
        uint32_t seed,
        const std::vector<JLexaChatMessage>& chatMessages,
        std::function<void(const std::string& token)> tokenCallback,
        std::function<void(bool cancelled, const std::string& errorMsg)> completionCallback,
        jlexa_benchmark_result* benchmark = nullptr,
        std::function<void(uint32_t, const std::string&)> benchmarkProgress = nullptr
    );

    void cancel();
    void resetCancellation();

private:
    JLexaLlamaBridge();
    ~JLexaLlamaBridge();

    struct Impl;
    Impl* pImpl;
};

#endif // JLEXA_LLAMA_BRIDGE_H
