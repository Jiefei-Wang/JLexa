#include "jlexa_speech_plugin.h"
#include "jlexa_whisper_bridge.h"
#include <atomic>
#include <cstdio>
#include <stdexcept>
#if JLEXA_WHISPER_OPTIMIZED
#include <sys/auxv.h>
#include <asm/hwcap.h>
#endif
namespace {
struct Backend { std::atomic<bool> stopped{false}; };
void error(char *out, uint32_t n, const char *text) {
    if (out && n) std::snprintf(out, n, "%s", text);
}
void *create(char *out, uint32_t n) {
#if JLEXA_WHISPER_OPTIMIZED
    if (!(getauxval(AT_HWCAP) & HWCAP_ASIMDHP) ||
        !(getauxval(AT_HWCAP) & HWCAP_ASIMDDP) ||
        !(getauxval(AT_HWCAP2) & HWCAP2_I8MM)) {
        error(out, n, "This Whisper CPU plugin requires FP16, dotprod and i8mm.");
        return nullptr;
    }
#endif
    try { return new Backend(); }
    catch (...) { error(out, n, "Whisper backend allocation failed"); return nullptr; }
}
void destroy(void *p) { JLexaWhisperBridge::instance().unloadModel(); delete static_cast<Backend *>(p); }
int32_t load(void *, const char *path, char *out, uint32_t n) {
    try {
        if (JLexaWhisperBridge::instance().loadModel(path ? path : "")) return 0;
        error(out, n, "Whisper model could not load");
    } catch (const std::exception &e) { error(out, n, e.what()); }
      catch (...) { error(out, n, "Whisper model load failed"); }
    return -1;
}
int32_t transcribe(void *p, const float *samples, uint32_t count, int32_t threads,
    const char *language, jlexa_speech_progress_fn progress,
    jlexa_speech_segment_fn emit, void *user, char *out, uint32_t n) {
    auto *b = static_cast<Backend *>(p);
    if (b->stopped) return 1;
    try {
        auto &engine = JLexaWhisperBridge::instance();
        const auto segments = engine.transcribe(samples, count, threads,
            language ? language : "en", [=](int percent) { if (progress) progress(user, percent); });
        if (b->stopped) return 1;
        auto failure = engine.getLastError();
        if (!failure.empty()) { error(out, n, failure.c_str()); return -1; }
        for (const auto &s : segments) {
            std::vector<jlexa_speech_token> tokens;
            for (const auto &t : s.tokens)
                tokens.push_back({t.text.c_str(), t.start_ms, t.end_ms, t.confidence});
            jlexa_speech_segment segment{s.text.c_str(), s.start_ms, s.end_ms,
                s.confidence, static_cast<uint32_t>(tokens.size()), tokens.data()};
            if (emit) emit(user, &segment);
        }
        return 0;
    } catch (const std::exception &e) { error(out, n, e.what()); }
      catch (...) { error(out, n, "Whisper transcription failed"); }
    return -1;
}
const jlexa_speech_api api{
    JLEXA_SPEECH_ABI, sizeof(jlexa_speech_api),
#if JLEXA_WHISPER_OPTIMIZED
    "JLexa Whisper Snapdragon CPU",
#else
    "JLexa Whisper CPU",
#endif
    "whisper.cpp", "1.0.0", "CPU", create, destroy, load,
    [](void *) { JLexaWhisperBridge::instance().unloadModel(); },
    [](void *) -> int32_t { return JLexaWhisperBridge::instance().isModelLoaded(); },
    transcribe,
    [](void *p) { static_cast<Backend *>(p)->stopped = true; JLexaWhisperBridge::instance().cancel(); },
    [](void *p) { static_cast<Backend *>(p)->stopped = false; JLexaWhisperBridge::instance().resetCancellation(); }
};
}
extern "C" const jlexa_speech_api *jlexa_speech_plugin_get_api() { return &api; }
