#include "jlexa_llama_bridge.h"


#include <chrono>
#include <cstdio>
#include <string>
#include <algorithm>
#include <cctype>

int main(int argc, char **argv) {
    setbuf(stdout, nullptr);
    if (argc != 3) return 2;

    auto &bridge = JLexaLlamaBridge::instance();
    JLexaLlamaRuntimeConfig config;
    config.backend = argv[2]; config.contextLength = 2048;
    config.batchSize = config.ubatchSize = 512; config.n_threads = 4;
    config.flashAttention = 0;
    if (!bridge.loadModel(argv[1], config)) return 3;
    int failures = 0;
    auto run = [&](const char *name, const std::string &prompt, int cancel_at, const std::string &exact) {
        // LlamaBridge.kt resets cancellation before each native request.
        bridge.resetCancellation();
        std::string answer, error;
        bool completed = false, cancelled = false;
        size_t tokens = 0;
        const auto begin = std::chrono::steady_clock::now();
        auto first = begin;
        bridge.generate(prompt, 100, 0.0f, 0.9f, 1234,
            {{"system", "You are a helpful assistant. Answer clearly and concisely."}, {"user", prompt}},
            [&](const std::string &token) {
                if (!tokens) first = std::chrono::steady_clock::now();
                answer += token; ++tokens;
                if (cancel_at > 0 && tokens == (size_t)cancel_at) bridge.cancel();
            },
            [&](bool c, const std::string &e) { completed = true; cancelled = c; error = e; });
        const auto end = std::chrono::steady_clock::now();
        std::string normalized = answer;
        normalized.erase(std::remove_if(normalized.begin(), normalized.end(),
            [](unsigned char c) { return std::isspace(c); }), normalized.end());
        bool passed = completed && error.empty() && tokens > 0 && cancelled == (cancel_at > 0);
        if (!exact.empty()) passed &= normalized == exact;
        failures += !passed;
        std::printf("BENCH backend=%s test=%s ms=%.3f first_token_ms=%.3f token_callbacks=%zu result=%s\n",
            argv[2], name, std::chrono::duration<double,std::milli>(end-begin).count(),
            std::chrono::duration<double,std::milli>(first-begin).count(), tokens, passed ? "PASS" : "FAIL");
        std::printf("ANSWER %s\nERROR %s\n", answer.c_str(), error.c_str());
    };
    std::string long_prompt = "Read these background notes, then answer the arithmetic question at the end.\n";
    for (int i = 0; i < 24; ++i)
        long_prompt += "A language learner listens to an audio lesson, reviews saved vocabulary, and practises speaking clearly every morning.\n";
    long_prompt += "What is 2 plus 2? Reply with only the number.";
    for (int trial = 0; trial < 2; ++trial) {
        run(trial ? "short-warm" : "short-cold", "What is 2 plus 2? Reply with only the number.", 0, "4");
        run(trial ? "long-warm" : "long-cold", long_prompt, 0, "4");
        run(trial ? "generate-warm" : "generate-cold", "Count from 1 to 20, using only numbers separated by commas.", 0, "");
    }
    run("cancel", "Count from 1 to 100, using only numbers separated by commas.", 5, "");
    run("after-cancel", "What is 2 plus 2? Reply with only the number.", 0, "4");
    bridge.unloadModel();
    if (!bridge.loadModel(argv[1], config)) return 4;
    run("after-reload", "What is 2 plus 2? Reply with only the number.", 0, "4");
    bridge.unloadModel();
    return failures ? 1 : 0;
}
