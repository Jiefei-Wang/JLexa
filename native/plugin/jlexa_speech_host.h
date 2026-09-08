#pragma once
#include "jlexa_whisper_bridge.h"
#include <memory>
#include <mutex>
class JLexaSpeechHost {
public:
    static JLexaSpeechHost &instance();
    void select(const std::string &path);
    std::vector<std::string> pluginInfo();
    bool loadModel(const std::string &);
    void unloadModel();
    bool isModelLoaded();
    std::vector<JLexaAudioSegment> transcribe(const float *, size_t, int,
        const std::string &, std::function<void(int)>);
    void cancel();
    void resetCancellation();
    std::string getLastError();
private:
    struct Backend;
    std::shared_ptr<Backend> current();
    std::shared_ptr<Backend> active;
    std::recursive_mutex operations;
    std::mutex state;
    std::string lastError;
};
