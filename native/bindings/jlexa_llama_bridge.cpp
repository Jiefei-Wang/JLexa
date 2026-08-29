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
};

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
    unloadModel();

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
        llama_model_free(pImpl->model);
        pImpl->model = nullptr;
        pImpl->vocab = nullptr;
        return false;
    }

    return true;
}

void JLexaLlamaBridge::unloadModel() {
    if (pImpl->ctx) {
        llama_free(pImpl->ctx);
        pImpl->ctx = nullptr;
    }
    if (pImpl->model) {
        llama_model_free(pImpl->model);
        pImpl->model = nullptr;
    }
    pImpl->vocab = nullptr;
}

bool JLexaLlamaBridge::isModelLoaded() const {
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
    std::function<void(const std::string& token)> tokenCallback
) {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    if (!pImpl->ctx || !pImpl->model || !pImpl->vocab || prompt.empty()) {
        return;
    }

    pImpl->isCancelled = false;

    // 1. Tokenize prompt
    const int n_prompt_max = static_cast<int>(prompt.length()) + 128;
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

    if (n_prompt <= 0) return;
    prompt_tokens.resize(n_prompt);

    // 2. Prepare Sampler
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler* smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature > 0.0f ? temperature : 0.7f));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(topP > 0.0f ? topP : 0.9f, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(42));

    // 3. Process prompt
    llama_batch batch = llama_batch_init(n_prompt + maxTokens, 0, 1);

    for (int i = 0; i < n_prompt; ++i) {
        batch.token[i] = prompt_tokens[i];
        batch.pos[i] = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i] = (i == n_prompt - 1) ? 1 : 0;
    }
    batch.n_tokens = n_prompt;

    if (llama_decode(pImpl->ctx, batch) != 0) {
        llama_sampler_free(smpl);
        llama_batch_free(batch);
        return;
    }

    // 4. Generation Loop
    int n_cur = n_prompt;
    int n_generated = 0;
    const int max_to_gen = maxTokens > 0 ? maxTokens : 256;

    char piece_buf[256];

    while (n_generated < max_to_gen && !pImpl->isCancelled) {
        // Sample next token
        const llama_token new_token_id = llama_sampler_sample(smpl, pImpl->ctx, -1);
        llama_sampler_accept(smpl, new_token_id);

        if (llama_vocab_is_eog(pImpl->vocab, new_token_id)) {
            break;
        }

        // Convert token to piece
        const int n_piece = llama_token_to_piece(
            pImpl->vocab,
            new_token_id,
            piece_buf,
            sizeof(piece_buf),
            0,
            true
        );

        if (n_piece > 0 && tokenCallback) {
            std::string piece(piece_buf, n_piece);
            tokenCallback(piece);
        }

        // Prepare batch for next step
        batch.token[0] = new_token_id;
        batch.pos[0] = n_cur;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;
        batch.n_tokens = 1;

        n_cur++;
        n_generated++;

        if (llama_decode(pImpl->ctx, batch) != 0) {
            break;
        }
    }

    llama_sampler_free(smpl);
    llama_batch_free(batch);
}
