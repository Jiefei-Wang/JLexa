#include "jlexa_whisper_bridge.h"
#include "whisper.h"
#include <mutex>
#include <atomic>
#include <iostream>

struct JLexaWhisperBridge::Impl {
    whisper_context* ctx = nullptr;
    std::mutex mtx;
    std::atomic<bool> isCancelled{false};
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
    if (pImpl->ctx != nullptr) {
        whisper_free(pImpl->ctx);
        pImpl->ctx = nullptr;
    }

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false; // CPU fallback on mobile for stability

    pImpl->ctx = whisper_init_from_file_with_params(modelPath.c_str(), cparams);
    return pImpl->ctx != nullptr;
}

void JLexaWhisperBridge::unloadModel() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    if (pImpl->ctx != nullptr) {
        whisper_free(pImpl->ctx);
        pImpl->ctx = nullptr;
    }
}

bool JLexaWhisperBridge::isModelLoaded() const {
    return pImpl->ctx != nullptr;
}

void JLexaWhisperBridge::cancel() {
    pImpl->isCancelled = true;
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

    if (pImpl->ctx == nullptr || samples == nullptr || n_samples == 0) {
        return results;
    }

    pImpl->isCancelled = false;

    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.print_special   = false;
    wparams.print_progress  = false;
    wparams.print_realtime  = false;
    wparams.print_timestamps = false;
    wparams.translate       = false;
    wparams.language        = language.empty() ? "en" : language.c_str();
    wparams.n_threads       = n_threads > 0 ? n_threads : 4;
    wparams.token_timestamps = true;

    if (whisper_full(pImpl->ctx, wparams, samples, static_cast<int>(n_samples)) != 0) {
        return results;
    }

    const int n_segments = whisper_full_n_segments(pImpl->ctx);
    for (int i = 0; i < n_segments; ++i) {
        if (pImpl->isCancelled) break;

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

        segment.confidence = token_count > 0 ? (total_prob / token_count) : 1.0f;
        results.push_back(segment);

        if (progressCallback) {
            progressCallback(static_cast<int>((i + 1) * 100 / n_segments));
        }
    }

    return results;
}
