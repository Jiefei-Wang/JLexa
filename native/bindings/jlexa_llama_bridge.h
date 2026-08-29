#ifndef JLEXA_LLAMA_BRIDGE_H
#define JLEXA_LLAMA_BRIDGE_H

#include <string>
#include <functional>
#include <cstdint>

class JLexaLlamaBridge {
public:
    static JLexaLlamaBridge& instance();

    bool loadModel(const std::string& modelPath, int contextLength = 2048, int n_threads = 4);
    void unloadModel();
    bool isModelLoaded() const;

    void generate(
        const std::string& prompt,
        int maxTokens,
        float temperature,
        float topP,
        std::function<void(const std::string& token)> tokenCallback
    );

    void cancel();

private:
    JLexaLlamaBridge();
    ~JLexaLlamaBridge();

    struct Impl;
    Impl* pImpl;
};

#endif // JLEXA_LLAMA_BRIDGE_H
