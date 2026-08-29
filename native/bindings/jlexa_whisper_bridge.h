#ifndef JLEXA_WHISPER_BRIDGE_H
#define JLEXA_WHISPER_BRIDGE_H

#include <string>
#include <vector>
#include <functional>
#include <cstdint>

struct JLexaTranscriptToken {
    std::string text;
    int64_t start_ms;
    int64_t end_ms;
    float confidence;
};

struct JLexaAudioSegment {
    int64_t start_ms;
    int64_t end_ms;
    std::string text;
    float confidence;
    std::vector<JLexaTranscriptToken> tokens;
};

class JLexaWhisperBridge {
public:
    static JLexaWhisperBridge& instance();

    bool loadModel(const std::string& modelPath);
    void unloadModel();
    bool isModelLoaded();

    std::vector<JLexaAudioSegment> transcribe(
        const float* samples,
        size_t n_samples,
        int n_threads = 4,
        const std::string& language = "en",
        std::function<void(int progress)> progressCallback = nullptr
    );

    void cancel();

private:
    JLexaWhisperBridge();
    ~JLexaWhisperBridge();

    struct Impl;
    Impl* pImpl;
};

#endif // JLEXA_WHISPER_BRIDGE_H
