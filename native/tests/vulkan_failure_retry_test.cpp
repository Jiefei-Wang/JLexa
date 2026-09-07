// Adreno 830 + Qwen2.5 Instruct Q4_K regression fixture. Deliberately bypass
// JLexa's batch=1 compatibility cap to request the unsupported eight-column
// shader. Both attempts must report failure and teardown must finish; before
// the fix the second attempt waited forever on an abandoned compile claim.
#include "llama.h"

#include <cstdio>
#include <cstring>
#include <exception>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "Usage: vulkan_failure_retry_test <Qwen2.5-Instruct-Q4_K.gguf>\n");
        return 2;
    }
    llama_backend_init();
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = 99;
    auto* model = llama_model_load_from_file(argv[1], model_params);
    if (!model) return 2;
    auto params = llama_context_default_params();
    params.n_ctx = 2048;
    params.n_batch = params.n_ubatch = 8;
    params.n_threads = params.n_threads_batch = 4;
    auto* context = llama_init_from_model(model, params);
    if (!context) {
        llama_model_free(model);
        return 2;
    }
    const char* prompt = "What is 2 plus 2? Reply with only the number.";
    std::vector<llama_token> tokens(100);
    const int count = llama_tokenize(llama_model_get_vocab(model), prompt,
        std::strlen(prompt), tokens.data(), tokens.size(), true, true);
    int failures = 0;
    if (count >= 8) {
        for (int attempt = 1; attempt <= 2; ++attempt) {
            try {
                llama_memory_clear(llama_get_memory(context), true);
                auto batch = llama_batch_get_one(tokens.data(), 8);
                const int status = llama_decode(context, batch);
                std::printf("ATTEMPT%d status=%d\n", attempt, status);
                if (status != 0) ++failures;
            } catch (const std::exception& error) {
                ++failures;
                std::printf("ATTEMPT%d error=%s\n", attempt, error.what());
            }
            std::fflush(stdout);
        }
    }
    llama_free(context);
    llama_model_free(model);
    std::printf("Repeated unsupported shader failures returned: %d\n", failures);
    return failures == 2 ? 0 : 1;
}
