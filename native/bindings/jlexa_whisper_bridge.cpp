#include "jlexa_whisper_bridge.h"
#include "whisper.h"
#include <mutex>
#include <atomic>
#include <iostream>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#ifdef __ANDROID__
#include <unistd.h>
#endif

static size_t jlexa_whisper_file_read(void* ctx, void* output, size_t size) {
    return std::fread(output, 1, size, static_cast<FILE*>(ctx));
}

static bool jlexa_whisper_file_eof(void* ctx) {
    return std::feof(static_cast<FILE*>(ctx)) != 0;
}

static void jlexa_whisper_file_close(void* ctx) {
    std::fclose(static_cast<FILE*>(ctx));
}

struct JLexaWhisperBridge::Impl {
    whisper_context* ctx = nullptr;
    std::mutex mtx;
    std::atomic<bool> isCancelled{false};
    std::string lastError;

    void unloadModelLocked() {
        if (ctx != nullptr) {
            whisper_free(ctx);
            ctx = nullptr;
        }
    }
};

JLexaWhisperBridge& JLexaWhisperBridge::instance() {
    static JLexaWhisperBridge inst;
    return inst;
}

JLexaWhisperBridge::JLexaWhisperBridge() : pImpl(new Impl()) {}

JLexaWhisperBridge::~JLexaWhisperBridge() {
    unloadModel();
    delete pImpl;
}

bool JLexaWhisperBridge::loadModel(const std::string& modelPath) {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    pImpl->unloadModelLocked();

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false; // CPU fallback on mobile for stability

    constexpr const char* procFdPrefix = "/proc/self/fd/";
    if (modelPath.rfind(procFdPrefix, 0) == 0) {
#ifdef __ANDROID__
        const char* fdText = modelPath.c_str() + std::strlen(procFdPrefix);
        char* end = nullptr;
        const long sourceFd = std::strtol(fdText, &end, 10);
        if (end == fdText || *end != '\0' || sourceFd < 0) return false;
        const int ownedFd = dup(static_cast<int>(sourceFd));
        if (ownedFd < 0) return false;
        FILE* file = fdopen(ownedFd, "rb");
        if (!file) {
            close(ownedFd);
            return false;
        }
        whisper_model_loader loader = {
            file,
            jlexa_whisper_file_read,
            jlexa_whisper_file_eof,
            jlexa_whisper_file_close,
        };
        pImpl->ctx = whisper_init_with_params(&loader, cparams);
#else
        pImpl->ctx = whisper_init_from_file_with_params(modelPath.c_str(), cparams);
#endif
    } else {
        pImpl->ctx = whisper_init_from_file_with_params(modelPath.c_str(), cparams);
    }
    return pImpl->ctx != nullptr;
}

void JLexaWhisperBridge::unloadModel() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    pImpl->unloadModelLocked();
}

bool JLexaWhisperBridge::isModelLoaded() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    return pImpl->ctx != nullptr;
}

void JLexaWhisperBridge::cancel() {
    pImpl->isCancelled = true;
}

void JLexaWhisperBridge::resetCancellation() {
    pImpl->isCancelled = false;
}

std::string JLexaWhisperBridge::getLastError() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    return pImpl->lastError;
}

std::vector<JLexaAudioSegment> JLexaWhisperBridge::transcribe(
    const float* samples,
    size_t n_samples,
    int n_threads,
    const std::string& language,
    std::function<void(int progress)> progressCallback
) {
    std::vector<JLexaAudioSegment> results;
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    pImpl->lastError.clear();

    if (pImpl->ctx == nullptr || samples == nullptr || n_samples == 0) {
        pImpl->lastError = "Whisper inference received no model or audio samples";
        return results;
    }

    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_special   = false;
    wparams.print_progress  = false;
    wparams.print_realtime  = false;
    wparams.print_timestamps = false;
    wparams.translate       = false;
    wparams.language        = language.empty() ? "en" : language.c_str();
    wparams.n_threads       = n_threads > 0 ? n_threads : 4;
    wparams.token_timestamps = true;

    // Connect abort callback to atomic cancellation state
    wparams.abort_callback = [](void* user_data) -> bool {
        auto* impl = static_cast<JLexaWhisperBridge::Impl*>(user_data);
        return impl ? impl->isCancelled.load() : false;
    };
    wparams.abort_callback_user_data = pImpl;

    // Connect progress callback
    if (progressCallback) {
        wparams.progress_callback = [](whisper_context* /*ctx*/, whisper_state* /*state*/, int progress, void* user_data) {
            auto* cb = static_cast<std::function<void(int)>*>(user_data);
            if (cb && *cb) {
                (*cb)(progress);
            }
        };
        wparams.progress_callback_user_data = &progressCallback;
    }

    if (whisper_full(pImpl->ctx, wparams, samples, static_cast<int>(n_samples)) != 0) {
        if (!pImpl->isCancelled.load()) {
            pImpl->lastError = "whisper_full inference failed";
        }
        return results;
    }

    if (pImpl->isCancelled.load()) {
        return results;
    }

    const int n_segments = whisper_full_n_segments(pImpl->ctx);
    for (int i = 0; i < n_segments; ++i) {
        if (pImpl->isCancelled.load()) break;

        const int64_t t0 = whisper_full_get_segment_t0(pImpl->ctx, i) * 10; // Convert centiseconds to ms
        const int64_t t1 = whisper_full_get_segment_t1(pImpl->ctx, i) * 10;
        const char* text_cstr = whisper_full_get_segment_text(pImpl->ctx, i);
        std::string seg_text = text_cstr ? text_cstr : "";

        JLexaAudioSegment segment;
        segment.start_ms = t0;
        segment.end_ms = t1;
        segment.text = seg_text;

        // Collect tokens
        const int n_tokens = whisper_full_n_tokens(pImpl->ctx, i);
        float total_prob = 0.0f;
        int token_count = 0;

        for (int j = 0; j < n_tokens; ++j) {
            const whisper_token token_id = whisper_full_get_token_id(pImpl->ctx, i, j);
            // Timestamp, language and other control tokens all live at or
            // above EOT in the current whisper.cpp vocabulary.
            if (token_id >= whisper_token_eot(pImpl->ctx)) continue;
            const char* token_str = whisper_full_get_token_text(pImpl->ctx, i, j);
            if (!token_str) continue;

            const float prob = whisper_full_get_token_p(pImpl->ctx, i, j);
            const int64_t tok_t0 = whisper_full_get_token_t0(pImpl->ctx, i, j) * 10;
            const int64_t tok_t1 = whisper_full_get_token_t1(pImpl->ctx, i, j) * 10;

            JLexaTranscriptToken token;
            token.text = token_str;
            token.start_ms = tok_t0;
            token.end_ms = tok_t1;
            token.confidence = prob;

            segment.tokens.push_back(token);
            total_prob += prob;
            token_count++;
        }

        segment.confidence = token_count > 0 ? (total_prob / token_count) : -1.0f;
        results.push_back(segment);
    }

    return results;
}
