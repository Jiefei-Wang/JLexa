#include "jlexa_llama_bridge.h"
#include "llama.h"
#include "ggml-backend.h"
#include <mutex>
#include <atomic>
#include <vector>
#include <cstring>
#include <chrono>
#include <random>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#ifdef __ANDROID__
#include <unistd.h>
#endif

#ifdef __ANDROID__
#include <android/log.h>
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "JLexaLlama", __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "JLexaLlama", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "JLexaLlama", __VA_ARGS__)
#else
#include <cstdio>
#define LOGI(...) do { printf("[JLexaLlama INFO] " __VA_ARGS__); printf("\n"); } while(0)
#define LOGW(...) do { printf("[JLexaLlama WARN] " __VA_ARGS__); printf("\n"); } while(0)
#define LOGE(...) do { fprintf(stderr, "[JLexaLlama ERROR] " __VA_ARGS__); fprintf(stderr, "\n"); } while(0)
#endif

struct JLexaLlamaBridge::Impl {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    FILE* modelFile = nullptr;
    const llama_vocab* vocab = nullptr;
    int n_threads = 4;
    std::mutex mtx;
    std::atomic<bool> isCancelled{false};
    JLexaActiveBackendInfo activeInfo{"", "", 0, 0, 0, 0, 0, -1};

    void unloadModelLocked() {
        if (ctx) {
            llama_free(ctx);
            ctx = nullptr;
        }
        if (model) {
            llama_model_free(model);
            model = nullptr;
        }
        if (modelFile) {
            std::fclose(modelFile);
            modelFile = nullptr;
        }
        vocab = nullptr;
        activeInfo = JLexaActiveBackendInfo{"", "", 0, 0, 0, 0, 0, -1};
    }
};

static std::string jlexa_backend_name(ggml_backend_dev_t dev) {
    if (!dev) return "";
    ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(dev);
    std::string name = reg && ggml_backend_reg_name(reg) ? ggml_backend_reg_name(reg) : "";
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
    if (name.find("vulkan") != std::string::npos) return "vulkan";
    if (name.find("opencl") != std::string::npos) return "opencl";
    if (name.find("cpu") != std::string::npos) return "cpu";
    return name;
}

static void process_utf8_accumulator(std::string& accum, std::string& out_valid, bool flush_all = false) {
    size_t i = 0;
    const size_t len = accum.length();

    while (i < len) {
        unsigned char c = static_cast<unsigned char>(accum[i]);

        if (c <= 0x7F) {
            out_valid.push_back(static_cast<char>(c));
            i += 1;
            continue;
        }

        size_t char_len = 0;
        if (c >= 0xC2 && c <= 0xDF) {
            char_len = 2;
        } else if (c >= 0xE0 && c <= 0xEF) {
            char_len = 3;
        } else if (c >= 0xF0 && c <= 0xF4) {
            char_len = 4;
        } else {
            // Invalid leading byte (0x80..0xC1, 0xF5..0xFF)
            out_valid += "\xEF\xBF\xBD";
            i += 1;
            continue;
        }

        if (i + char_len > len) {
            if (!flush_all) {
                bool prefix_valid = true;
                if (char_len == 3 && (i + 1 < len)) {
                    unsigned char c1 = static_cast<unsigned char>(accum[i + 1]);
                    if ((c1 & 0xC0) != 0x80) prefix_valid = false;
                    if (c == 0xE0 && (c1 < 0xA0 || c1 > 0xBF)) prefix_valid = false;
                    if (c == 0xED && (c1 < 0x80 || c1 > 0x9F)) prefix_valid = false;
                } else if (char_len == 4) {
                    if (i + 1 < len) {
                        unsigned char c1 = static_cast<unsigned char>(accum[i + 1]);
                        if ((c1 & 0xC0) != 0x80) prefix_valid = false;
                        if (c == 0xF0 && (c1 < 0x90 || c1 > 0xBF)) prefix_valid = false;
                        if (c == 0xF4 && (c1 < 0x80 || c1 > 0x8F)) prefix_valid = false;
                    }
                    if (i + 2 < len) {
                        unsigned char c2 = static_cast<unsigned char>(accum[i + 2]);
                        if ((c2 & 0xC0) != 0x80) prefix_valid = false;
                    }
                }

                if (prefix_valid) {
                    break;
                }
            }
            out_valid += "\xEF\xBF\xBD";
            i += 1;
            continue;
        }

        bool valid = true;
        if (char_len == 2) {
            unsigned char c1 = static_cast<unsigned char>(accum[i + 1]);
            if ((c1 & 0xC0) != 0x80) valid = false;
        } else if (char_len == 3) {
            unsigned char c1 = static_cast<unsigned char>(accum[i + 1]);
            unsigned char c2 = static_cast<unsigned char>(accum[i + 2]);
            if ((c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80) valid = false;
            if (c == 0xE0 && (c1 < 0xA0 || c1 > 0xBF)) valid = false;
            if (c == 0xED && (c1 < 0x80 || c1 > 0x9F)) valid = false;
        } else if (char_len == 4) {
            unsigned char c1 = static_cast<unsigned char>(accum[i + 1]);
            unsigned char c2 = static_cast<unsigned char>(accum[i + 2]);
            unsigned char c3 = static_cast<unsigned char>(accum[i + 3]);
            if ((c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80) valid = false;
            if (c == 0xF0 && (c1 < 0x90 || c1 > 0xBF)) valid = false;
            if (c == 0xF4 && (c1 < 0x80 || c1 > 0x8F)) valid = false;
        }

        if (valid) {
            out_valid.append(accum, i, char_len);
            i += char_len;
        } else {
            out_valid += "\xEF\xBF\xBD";
            i += 1;
        }
    }

    if (i < len) {
        accum = accum.substr(i);
    } else {
        accum.clear();
    }
}

JLexaLlamaBridge& JLexaLlamaBridge::instance() {
    static JLexaLlamaBridge inst;
    return inst;
}

JLexaLlamaBridge::JLexaLlamaBridge() : pImpl(new Impl()) {
    llama_backend_init();
    LOGI("JLexaLlamaBridge initialized with llama_backend_init()");
}

JLexaLlamaBridge::~JLexaLlamaBridge() {
    unloadModel();
    llama_backend_free();
    delete pImpl;
}

std::vector<JLexaBackendInfo> JLexaLlamaBridge::getAvailableBackends() {
    std::vector<JLexaBackendInfo> result;

    // CPU is always compiled and available
    JLexaBackendInfo cpuInfo;
    cpuInfo.backend = "cpu";
    cpuInfo.compiled = true;
    cpuInfo.available = true;
    cpuInfo.deviceName = "CPU";
    cpuInfo.reasonUnavailable = "";
    result.push_back(cpuInfo);

    bool vulkanFound = false;
    std::string vulkanDevName = "";
    bool openclFound = false;
    std::string openclDevName = "";

    const size_t dev_count = ggml_backend_dev_count();
    for (size_t i = 0; i < dev_count; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (!dev) continue;
        const char* ddesc = ggml_backend_dev_description(dev);
        std::string sname = jlexa_backend_name(dev);
        std::string sdesc = ddesc ? ddesc : "";

        if (sname == "vulkan") {
            vulkanFound = true;
            vulkanDevName = !sdesc.empty() ? sdesc : sname;
        } else if (sname == "opencl") {
            openclFound = true;
            openclDevName = !sdesc.empty() ? sdesc : sname;
        }
    }

#ifdef JLEXA_HAS_VULKAN
    JLexaBackendInfo vkInfo;
    vkInfo.backend = "vulkan";
    vkInfo.compiled = true;
    vkInfo.available = vulkanFound;
    vkInfo.deviceName = vulkanFound ? vulkanDevName : "";
    vkInfo.reasonUnavailable = vulkanFound ? "" : "No compatible Vulkan compute device found on this system.";
    result.push_back(vkInfo);
#else
    JLexaBackendInfo vkInfo;
    vkInfo.backend = "vulkan";
    vkInfo.compiled = false;
    vkInfo.available = false;
    vkInfo.deviceName = "";
    vkInfo.reasonUnavailable = "Vulkan backend is not compiled in this build.";
    result.push_back(vkInfo);
#endif

#ifdef GGML_USE_OPENCL
    JLexaBackendInfo clInfo;
    clInfo.backend = "opencl";
    clInfo.compiled = true;
    clInfo.available = openclFound;
    clInfo.deviceName = openclFound ? openclDevName : "";
    clInfo.reasonUnavailable = openclFound ? "" : "No compatible OpenCL compute device found on this system.";
    result.push_back(clInfo);
#else
    JLexaBackendInfo clInfo;
    clInfo.backend = "opencl";
    clInfo.compiled = false;
    clInfo.available = false;
    clInfo.deviceName = "";
    clInfo.reasonUnavailable = "OpenCL backend is not compiled in this build.";
    result.push_back(clInfo);
#endif

    return result;
}

JLexaActiveBackendInfo JLexaLlamaBridge::getActiveBackendInfo() {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    return pImpl->activeInfo;
}

bool JLexaLlamaBridge::loadModel(const std::string& modelPath, int contextLength, int n_threads) {
    JLexaLlamaRuntimeConfig cfg;
    cfg.backend = "auto";
    cfg.contextLength = contextLength;
    cfg.n_threads = n_threads;
    return loadModel(modelPath, cfg);
}

bool JLexaLlamaBridge::loadModel(const std::string& modelPath, const JLexaLlamaRuntimeConfig& config) {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    pImpl->unloadModelLocked();

    LOGI("Loading LLM model from: %s", modelPath.c_str());
    LOGI("Config: backend=%s, ctx=%d, threads=%d, gpuLayers=%d, batch=%d, ubatch=%d, flashAttn=%d",
         config.backend.c_str(), config.contextLength, config.n_threads, config.gpuLayers,
         config.batchSize, config.ubatchSize, config.flashAttention);

    pImpl->n_threads = config.n_threads > 0 ? config.n_threads : 4;

    llama_model_params mparams = llama_model_default_params();

    std::string selectedBackend = "cpu";
    std::string activeDeviceName = "CPU";
    int resolvedGpuLayers = 0;

    ggml_backend_dev_t vulkan_dev = nullptr;
    ggml_backend_dev_t opencl_dev = nullptr;
    const size_t dev_count = ggml_backend_dev_count();
    for (size_t i = 0; i < dev_count; ++i) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (!dev) continue;
        const std::string backend = jlexa_backend_name(dev);
        if (backend == "vulkan" && !vulkan_dev) vulkan_dev = dev;
        if (backend == "opencl" && !opencl_dev) opencl_dev = dev;
    }
    ggml_backend_dev_t target_gpu_dev = nullptr;

    if (config.backend == "cpu") {
        selectedBackend = "cpu";
        activeDeviceName = "CPU";
        mparams.n_gpu_layers = 0;
        resolvedGpuLayers = 0;
    } else if (config.backend == "vulkan") {
        target_gpu_dev = vulkan_dev;
        if (!target_gpu_dev) {
            LOGE("Explicit Vulkan backend requested but no accelerated GPU device is available");
            return false;
        }
        selectedBackend = "vulkan";
        activeDeviceName = ggml_backend_dev_description(target_gpu_dev) ? ggml_backend_dev_description(target_gpu_dev) : "Vulkan GPU";
        mparams.n_gpu_layers = config.gpuLayers >= 0 ? config.gpuLayers : -1;
        resolvedGpuLayers = mparams.n_gpu_layers;
    } else if (config.backend == "opencl") {
        target_gpu_dev = opencl_dev;
        if (!target_gpu_dev) {
            LOGE("Explicit OpenCL backend requested but no OpenCL device is available");
            return false;
        }
        selectedBackend = "opencl";
        activeDeviceName = ggml_backend_dev_description(target_gpu_dev) ? ggml_backend_dev_description(target_gpu_dev) : "OpenCL GPU";
        mparams.n_gpu_layers = config.gpuLayers >= 0 ? config.gpuLayers : -1;
        resolvedGpuLayers = mparams.n_gpu_layers;
    } else { // "auto"
        target_gpu_dev = vulkan_dev ? vulkan_dev : opencl_dev;
        if (target_gpu_dev) {
            selectedBackend = jlexa_backend_name(target_gpu_dev);
            activeDeviceName = ggml_backend_dev_description(target_gpu_dev) ? ggml_backend_dev_description(target_gpu_dev) : "Accelerated GPU";
            mparams.n_gpu_layers = config.gpuLayers >= 0 ? config.gpuLayers : -1;
            resolvedGpuLayers = mparams.n_gpu_layers;
            LOGI("Auto backend selected GPU device: %s", activeDeviceName.c_str());
        } else {
            selectedBackend = "cpu";
            activeDeviceName = "CPU";
            mparams.n_gpu_layers = 0;
            resolvedGpuLayers = 0;
            LOGI("Auto backend selected CPU fallback");
        }
    }

    ggml_backend_dev_t selected_devices[] = {target_gpu_dev, nullptr};
    if (target_gpu_dev) mparams.devices = selected_devices;

    constexpr const char* procFdPrefix = "/proc/self/fd/";
    if (modelPath.rfind(procFdPrefix, 0) == 0) {
#ifdef __ANDROID__
        const char* fdText = modelPath.c_str() + std::strlen(procFdPrefix);
        char* end = nullptr;
        const long sourceFd = std::strtol(fdText, &end, 10);
        if (end == fdText || *end != '\0' || sourceFd < 0) {
            LOGE("Invalid SAF file descriptor path: %s", modelPath.c_str());
            return false;
        }
        const int ownedFd = dup(static_cast<int>(sourceFd));
        if (ownedFd < 0) {
            LOGE("Could not duplicate SAF model file descriptor");
            return false;
        }
        FILE* file = fdopen(ownedFd, "rb");
        if (!file) {
            close(ownedFd);
            LOGE("Could not create FILE stream for SAF model descriptor");
            return false;
        }
        pImpl->model = llama_model_load_from_file_ptr(file, mparams);
        if (pImpl->model) {
            pImpl->modelFile = file;
        } else {
            std::fclose(file);
        }
#else
        pImpl->model = llama_model_load_from_file(modelPath.c_str(), mparams);
#endif
    } else {
        pImpl->model = llama_model_load_from_file(modelPath.c_str(), mparams);
    }
    if (!pImpl->model) {
        LOGE("Failed to load llama_model from file: %s", modelPath.c_str());
        return false;
    }

    pImpl->vocab = llama_model_get_vocab(pImpl->model);

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = config.contextLength > 0 ? config.contextLength : 2048;
    cparams.n_batch = config.batchSize > 0 ? config.batchSize : 512;
    cparams.n_ubatch = config.ubatchSize > 0 ? config.ubatchSize : 512;
    cparams.n_threads = pImpl->n_threads;
    cparams.n_threads_batch = pImpl->n_threads;

    if (config.flashAttention == 1) {
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    } else if (config.flashAttention == 0) {
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    } else {
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    }

    pImpl->ctx = llama_init_from_model(pImpl->model, cparams);
    if (!pImpl->ctx) {
        LOGE("Failed to initialize llama_context from model");
        pImpl->unloadModelLocked();
        return false;
    }

    pImpl->activeInfo = JLexaActiveBackendInfo{
        selectedBackend,
        activeDeviceName,
        resolvedGpuLayers,
        static_cast<int>(llama_n_ctx(pImpl->ctx)),
        pImpl->n_threads,
        static_cast<int>(llama_n_batch(pImpl->ctx)),
        static_cast<int>(llama_n_ubatch(pImpl->ctx)),
        config.flashAttention
    };

    LOGI("LLM model successfully loaded! Active backend=%s, device=%s, n_ctx=%d, n_batch=%d, threads=%d",
         pImpl->activeInfo.backend.c_str(), pImpl->activeInfo.deviceName.c_str(),
         pImpl->activeInfo.contextLength, pImpl->activeInfo.batchSize, pImpl->activeInfo.threads);

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

void JLexaLlamaBridge::resetCancellation() {
    pImpl->isCancelled = false;
}

void JLexaLlamaBridge::generate(
    const std::string& prompt,
    int maxTokens,
    float temperature,
    float topP,
    uint32_t seed,
    const std::vector<JLexaChatMessage>& chatMessages,
    std::function<void(const std::string& token)> tokenCallback,
    std::function<void(bool cancelled, const std::string& errorMsg)> completionCallback
) {
    std::lock_guard<std::mutex> lock(pImpl->mtx);
    try {
    if (pImpl->isCancelled.load()) {
        if (completionCallback) completionCallback(true, "");
        return;
    }

    if (!pImpl->ctx || !pImpl->model || !pImpl->vocab) {
        if (completionCallback) completionCallback(false, "Model not loaded");
        return;
    }

    std::string prompt_to_use = prompt;

    // Apply chat template if chatMessages are provided and model supports template
    if (!chatMessages.empty()) {
        const char* tmpl = llama_model_chat_template(pImpl->model, nullptr);
        if (tmpl != nullptr) {
            std::vector<llama_chat_message> msgs;
            msgs.reserve(chatMessages.size());
            for (const auto& msg : chatMessages) {
                msgs.push_back({msg.role.c_str(), msg.content.c_str()});
            }

            int32_t alloc_size = 2048;
            for (const auto& m : chatMessages) {
                alloc_size += static_cast<int32_t>(m.content.length() + 64);
            }
            std::vector<char> buf(alloc_size);
            int32_t res = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(), static_cast<int32_t>(buf.size()));
            if (res > static_cast<int32_t>(buf.size())) {
                buf.resize(res + 1);
                res = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(), static_cast<int32_t>(buf.size()));
            }
            if (res > 0) {
                prompt_to_use = std::string(buf.data(), res);
            }
        }
    }

    if (prompt_to_use.empty()) {
        if (completionCallback) completionCallback(false, "Empty prompt");
        return;
    }

    // Clear KV cache / sequence memory before generation
    llama_memory_t mem = llama_get_memory(pImpl->ctx);
    if (mem) {
        llama_memory_clear(mem, true);
    }

    // 1. Tokenize prompt
    const int n_prompt_max = static_cast<int>(prompt_to_use.length()) + 256;
    std::vector<llama_token> prompt_tokens(n_prompt_max);
    int n_prompt = llama_tokenize(
        pImpl->vocab,
        prompt_to_use.c_str(),
        static_cast<int32_t>(prompt_to_use.length()),
        prompt_tokens.data(),
        n_prompt_max,
        true, // add BOS
        true  // parse special
    );

    if (n_prompt < 0) {
        prompt_tokens.resize(-n_prompt);
        n_prompt = llama_tokenize(
            pImpl->vocab,
            prompt_to_use.c_str(),
            static_cast<int32_t>(prompt_to_use.length()),
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

    if (pImpl->isCancelled.load()) {
        if (completionCallback) completionCallback(true, "");
        return;
    }

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

    // 2. Prepare Sampler with RAII and non-deterministic seed if not specified
    struct SamplerGuard {
        llama_sampler* smpl = nullptr;
        ~SamplerGuard() { if (smpl) llama_sampler_free(smpl); }
    } sampler_guard;

    uint32_t actual_seed = seed;
    if (actual_seed == 0) {
        actual_seed = static_cast<uint32_t>(std::chrono::system_clock::now().time_since_epoch().count());
    }

    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    sampler_guard.smpl = llama_sampler_chain_init(sparams);
    // Zero is a valid deterministic temperature. Defaults are applied in the
    // Dart/Kotlin request layer, so native must preserve the explicit value.
    llama_sampler_chain_add(sampler_guard.smpl, llama_sampler_init_temp(temperature >= 0.0f ? temperature : 0.7f));
    llama_sampler_chain_add(sampler_guard.smpl, llama_sampler_init_top_p(topP > 0.0f ? topP : 0.9f, 1));
    llama_sampler_chain_add(sampler_guard.smpl, llama_sampler_init_dist(actual_seed));

    // 3. Process prompt with RAII batch and chunking by n_batch
    const uint32_t n_batch = llama_n_batch(pImpl->ctx);
    struct BatchGuard {
        llama_batch batch;
        bool active = false;
        ~BatchGuard() { if (active) llama_batch_free(batch); }
    } batch_guard;

    const int alloc_batch_size = static_cast<int>(std::max(n_batch, (uint32_t)1));
    batch_guard.batch = llama_batch_init(alloc_batch_size, 0, 1);
    batch_guard.active = true;

    for (int i = 0; i < n_prompt; i += static_cast<int>(n_batch)) {
        if (pImpl->isCancelled.load()) {
            if (completionCallback) completionCallback(true, "");
            return;
        }

        const int n_eval = std::min(static_cast<int>(n_batch), n_prompt - i);
        batch_guard.batch.n_tokens = n_eval;

        for (int j = 0; j < n_eval; ++j) {
            const int pos = i + j;
            batch_guard.batch.token[j] = prompt_tokens[pos];
            batch_guard.batch.pos[j] = pos;
            batch_guard.batch.n_seq_id[j] = 1;
            batch_guard.batch.seq_id[j][0] = 0;
            batch_guard.batch.logits[j] = (pos == n_prompt - 1) ? 1 : 0;
        }

        if (llama_decode(pImpl->ctx, batch_guard.batch) != 0) {
            LOGE("Failed to decode prompt chunk at offset %d (n_eval=%d)", i, n_eval);
            if (completionCallback) completionCallback(false, "Failed to decode prompt");
            return;
        }
    }

    // 4. Generation Loop with UTF-8 piece boundary safety
    std::string utf8_accum;
    int n_cur = n_prompt;
    int n_generated = 0;
    char piece_buf[256];
    bool decode_failed = false;

    while (n_generated < max_to_gen && !pImpl->isCancelled && static_cast<uint32_t>(n_cur) < n_ctx) {
        const llama_token new_token_id = llama_sampler_sample(sampler_guard.smpl, pImpl->ctx, -1);
        llama_sampler_accept(sampler_guard.smpl, new_token_id);

        if (llama_vocab_is_eog(pImpl->vocab, new_token_id)) {
            break;
        }

        int n_piece = llama_token_to_piece(
            pImpl->vocab,
            new_token_id,
            piece_buf,
            sizeof(piece_buf),
            0,
            true
        );

        char* piece_ptr = piece_buf;
        std::vector<char> large_buf;
        if (n_piece < 0) {
            large_buf.resize(-n_piece);
            n_piece = llama_token_to_piece(
                pImpl->vocab,
                new_token_id,
                large_buf.data(),
                static_cast<int32_t>(large_buf.size()),
                0,
                true
            );
            piece_ptr = large_buf.data();
        }

        if (n_piece > 0) {
            utf8_accum.append(piece_ptr, n_piece);
            std::string token_to_emit;
            process_utf8_accumulator(utf8_accum, token_to_emit, false);
            if (!token_to_emit.empty() && tokenCallback) {
                tokenCallback(token_to_emit);
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
            LOGE("Failed to decode sampled token at pos %d", n_cur - 1);
            decode_failed = true;
            break;
        }
    }

    // Flush any remaining accumulated bytes
    if (!utf8_accum.empty()) {
        std::string token_to_emit;
        process_utf8_accumulator(utf8_accum, token_to_emit, true);
        if (!token_to_emit.empty() && tokenCallback) {
            tokenCallback(token_to_emit);
        }
    }

    if (completionCallback) {
        if (pImpl->isCancelled.load()) {
            completionCallback(true, "");
        } else if (decode_failed) {
            completionCallback(false, "Decode failed mid-generation");
        } else {
            completionCallback(false, "");
        }
    }
    } catch (const std::exception& error) {
        LOGE("Native inference exception: %s", error.what());
        if (completionCallback) {
            completionCallback(
                false,
                std::string("Native inference failed: ") + error.what()
            );
        }
    } catch (...) {
        LOGE("Native inference failed with an unknown exception");
        if (completionCallback) {
            completionCallback(false, "Native inference failed unexpectedly");
        }
    }
}
