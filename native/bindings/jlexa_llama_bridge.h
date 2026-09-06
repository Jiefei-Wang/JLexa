#ifndef JLEXA_LLAMA_BRIDGE_H
#define JLEXA_LLAMA_BRIDGE_H

#include <string>
#include <vector>
#include <functional>
#include <cstdint>

struct JLexaChatMessage {
    std::string role;
    std::string content;
};

struct JLexaBackendInfo {
    std::string backend; // "cpu", "vulkan", "opencl"
    bool compiled;
    bool available;
    std::string deviceName;
    std::string reasonUnavailable;
};

struct JLexaActiveBackendInfo {
    std::string backend;
    std::string deviceName;
    int gpuLayers;
    int contextLength;
    int threads;
    int batchSize;
    int ubatchSize;
    int flashAttention; // -1 auto, 0 off, 1 on
};

struct JLexaLlamaRuntimeConfig {
    std::string backend = "auto"; // "auto", "cpu", "vulkan", "opencl"
    int contextLength = 2048;
    int n_threads = 4;
    int gpuLayers = -1; // -1 auto/all (when accelerated), 0 none, >0 custom
    int batchSize = 512;
    int ubatchSize = 512;
    int flashAttention = -1; // -1 auto, 0 disabled, 1 enabled
};

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
        std::function<void(bool cancelled, const std::string& errorMsg)> completionCallback
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
