#include "jlexa_llama_bridge.h"
#include "llama.h"
#include <mutex>
#include <atomic>
#include <vector>
#include <cstring>

struct JLexaLlamaBridge::Impl {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    const llama_vocab* vocab = nullptr;
    int n_threads = 4;
    std::mutex mtx;
    std::atomic<bool> isCancelled{false};

    void unloadModelLocked() {
        if (ctx) {
            llama_free(ctx);
            ctx = nullptr;
        }
        if (model) {
            llama_model_free(model);
            model = nullptr;
        }
        vocab = nullptr;
    }
};

static size_t get_valid_utf8_length(const std::string& str) {
    size_t i = 0;
    size_t last_valid = 0;
    const size_t len = str.length();
    while (i < len) {
        unsigned char c = static_cast<unsigned char>(str[i]);
        size_t char_len = 0;
        if (c <= 0x7F) {
            char_len = 1;
        } else if ((c & 0xE0) == 0xC0) {
            char_len = 2;
        } else if ((c & 0xF0) == 0xE0) {
            char_len = 3;
        } else if ((c & 0xF8) == 0xF0) {
            char_len = 4;
        } else {
            i++;
            continue;
        }

        if (i + char_len <= len) {
            bool valid = true;
            for (size_t k = 1; k < char_len; ++k) {
                if ((static_cast<unsigned char>(str[i + k]) & 0xC0) != 0x80) {
                    valid = false;
                    break;
                }
            }
            if (valid) {
                i += char_len;
                last_valid = i;
            } else {
                i++;
            }
        } else {
            break;
        }
    }
    return last_valid;
}

JLexaLlamaBridge& JLexaLlamaBridge::instance() {
    static JLexaLlamaBridge inst;
    return inst;
}

JLexaLlamaBridge::JLexaLlamaBridge() : pImpl(new Impl()) {
    llama_backend_init();
}

JLexaLlamaBridge::~JLexaLlamaBridge() {
    unloadModel();
    llama_backend_free();
    delete pImpl;
}

bool JLexaLlamaBridge::loadModel(const std::string& modelPath, int contextLength, int n_threads) {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    pImpl->unloadModelLocked();

    pImpl->n_threads = n_threads > 0 ? n_threads : 4;

    llama_model_params mparams = llama_model_default_params();
    pImpl->model = llama_model_load_from_file(modelPath.c_str(), mparams);
    if (!pImpl->model) {
        return false;
    }

    pImpl->vocab = llama_model_get_vocab(pImpl->model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = contextLength > 0 ? contextLength : 2048;
    cparams.n_threads = pImpl->n_threads;
    cparams.n_threads_batch = pImpl->n_threads;

    pImpl->ctx = llama_init_from_model(pImpl->model, cparams);
    if (!pImpl->ctx) {
        pImpl->unloadModelLocked();
        return false;
    }

    return true;
}

void JLexaLlamaBridge::unloadModel() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    pImpl->unloadModelLocked();
}

bool JLexaLlamaBridge::isModelLoaded() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    return pImpl->ctx != nullptr && pImpl->model != nullptr;
}

void JLexaLlamaBridge::cancel() {
    pImpl->isCancelled = true;
}

void JLexaLlamaBridge::generate(
    const std::string& prompt,
    int maxTokens,
    float temperature,
    float topP,
    std::function<void(const std::string& token)> tokenCallback,
    std::function<void(bool cancelled, const std::string& errorMsg)> completionCallback
) {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    if (!pImpl->ctx || !pImpl->model || !pImpl->vocab) {
        if (completionCallback) completionCallback(false, "Model not loaded");
        return;
    }
    if (prompt.empty()) {
        if (completionCallback) completionCallback(false, "Empty prompt");
        return;
    }

    pImpl->isCancelled = false;

    // Clear KV cache / sequence memory before generation
    llama_memory_t mem = llama_get_memory(pImpl->ctx);
    if (mem) {
        llama_memory_clear(mem, true);
    }

    // 1. Tokenize prompt
    const int n_prompt_max = static_cast<int>(prompt.length()) + 256;
    std::vector<llama_token> prompt_tokens(n_prompt_max);
    int n_prompt = llama_tokenize(
        pImpl->vocab,
        prompt.c_str(),
        static_cast<int32_t>(prompt.length()),
        prompt_tokens.data(),
        n_prompt_max,
        true, // add BOS
        true  // parse special
    );

    if (n_prompt < 0) {
        prompt_tokens.resize(-n_prompt);
        n_prompt = llama_tokenize(
            pImpl->vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.length()),
            prompt_tokens.data(),
            prompt_tokens.size(),
            true,
            true
        );
    }

    if (n_prompt <= 0) {
        if (completionCallback) completionCallback(false, "Prompt tokenization failed");
        return;
    }
    prompt_tokens.resize(n_prompt);

    // Context capacity validation
    const uint32_t n_ctx = llama_n_ctx(pImpl->ctx);
    if (static_cast<uint32_t>(n_prompt) >= n_ctx) {
        if (completionCallback) {
            completionCallback(false, "Prompt exceeds context window (" + std::to_string(n_prompt) + " >= " + std::to_string(n_ctx) + ")");
        }
        return;
    }

    int max_to_gen = maxTokens > 0 ? maxTokens : 256;
    if (static_cast<uint32_t>(n_prompt + max_to_gen) > n_ctx) {
        max_to_gen = static_cast<int>(n_ctx - n_prompt);
    }

    // 2. Prepare Sampler with RAII
    struct SamplerGuard {
        llama_sampler* smpl = nullptr;
        ~SamplerGuard() { if (smpl) llama_sampler_free(smpl); }
    } sampler_guard;

    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sampler_guard.smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(sampler_guard.smpl, llama_sampler_init_temp(temperature > 0.0f ? temperature : 0.7f));
    llama_sampler_chain_add(sampler_guard.smpl, llama_sampler_init_top_p(topP > 0.0f ? topP : 0.9f, 1));
    llama_sampler_chain_add(sampler_guard.smpl, llama_sampler_init_dist(42));

    // 3. Process prompt with RAII batch
    struct BatchGuard {
        llama_batch batch;
        bool active = false;
        ~BatchGuard() { if (active) llama_batch_free(batch); }
    } batch_guard;

    batch_guard.batch = llama_batch_init(n_prompt + max_to_gen, 0, 1);
    batch_guard.active = true;

    for (int i = 0; i < n_prompt; ++i) {
        batch_guard.batch.token[i] = prompt_tokens[i];
        batch_guard.batch.pos[i] = i;
        batch_guard.batch.n_seq_id[i] = 1;
        batch_guard.batch.seq_id[i][0] = 0;
        batch_guard.batch.logits[i] = (i == n_prompt - 1) ? 1 : 0;
    }
    batch_guard.batch.n_tokens = n_prompt;

    if (llama_decode(pImpl->ctx, batch_guard.batch) != 0) {
        if (completionCallback) completionCallback(false, "Failed to decode prompt");
        return;
    }

    // 4. Generation Loop with UTF-8 piece boundary safety
    std::string utf8_accum;
    int n_cur = n_prompt;
    int n_generated = 0;
    char piece_buf[256];

    while (n_generated < max_to_gen && !pImpl->isCancelled && static_cast<uint32_t>(n_cur) < n_ctx) {
        const llama_token new_token_id = llama_sampler_sample(sampler_guard.smpl, pImpl->ctx, -1);
        llama_sampler_accept(sampler_guard.smpl, new_token_id);

        if (llama_vocab_is_eog(pImpl->vocab, new_token_id)) {
            break;
        }

        const int n_piece = llama_token_to_piece(
            pImpl->vocab,
            new_token_id,
            piece_buf,
            sizeof(piece_buf),
            0,
            true
        );

        if (n_piece > 0) {
            utf8_accum.append(piece_buf, n_piece);
            size_t valid_len = get_valid_utf8_length(utf8_accum);
            if (valid_len > 0) {
                std::string token_to_emit = utf8_accum.substr(0, valid_len);
                utf8_accum.erase(0, valid_len);
                if (tokenCallback) {
                    tokenCallback(token_to_emit);
                }
            }
        }

        batch_guard.batch.token[0] = new_token_id;
        batch_guard.batch.pos[0] = n_cur;
        batch_guard.batch.n_seq_id[0] = 1;
        batch_guard.batch.seq_id[0][0] = 0;
        batch_guard.batch.logits[0] = 1;
        batch_guard.batch.n_tokens = 1;

        n_cur++;
        n_generated++;

        if (llama_decode(pImpl->ctx, batch_guard.batch) != 0) {
            break;
        }
    }

    // Flush any remaining accumulated bytes if valid
    if (!utf8_accum.empty() && tokenCallback) {
        tokenCallback(utf8_accum);
    }

    if (completionCallback) {
        completionCallback(pImpl->isCancelled.load(), "");
    }
}
