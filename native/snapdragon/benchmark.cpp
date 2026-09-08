#include "jlexa_plugin.h"
#include "jlexa_benchmark.h"
#include <dlfcn.h>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <string>

struct Progress {
  const jlexa_plugin_api *api;
  void *handle;
  std::string source, output;
  int cancel_after = 0, callbacks = 0;
};

static void progress(void *p, uint32_t phase, const char *text,
                     const jlexa_benchmark_result *) {
  auto &s = *static_cast<Progress *>(p);
  if (phase == 0) s.source += text;
  if (phase == 2) {
    s.output += text;
    if (s.cancel_after > 0 && ++s.callbacks == s.cancel_after)
      s.api->stop(s.handle);
  }
}

int main(int argc, char **argv) {
  setbuf(stdout, nullptr);
  if (argc < 3 || argc > 5) return 2;
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 3; }
  auto get_api = reinterpret_cast<const jlexa_plugin_api *(*)()>(
      dlsym(library, "jlexa_plugin_get_api"));
  auto get_bench = reinterpret_cast<const jlexa_benchmark_api *(*)()>(
      dlsym(library, "jlexa_plugin_get_benchmark_api"));
  if (!get_api || !get_bench) return 4;
  const auto *api = get_api(); const auto *bench = get_bench();
  if (api->abi_version != JLEXA_PLUGIN_ABI ||
      bench->abi_version != JLEXA_BENCHMARK_ABI) return 5;
  char error[1024]{};
  void *handle = api->create(error, sizeof(error));
  if (!handle) { std::puts(error); return 6; }
  jlexa_runtime runtime{};
  std::snprintf(runtime.backend, sizeof(runtime.backend), "%s", argc > 4 ? argv[4] : "cpu");
  runtime.context_length = 2048;
  runtime.threads = argc > 3 ? std::atoi(argv[3]) : 4;
  runtime.batch_size = runtime.micro_batch_size = 512;
  runtime.gpu_layers = 99;
  runtime.flash_attention = 0;
  if (api->load_model(handle, argv[2], &runtime, error, sizeof(error))) {
    std::puts(error); api->destroy(handle); return 7;
  }
  char device[256]{};
  api->active_runtime(handle, &runtime, device, sizeof(device));
  std::printf("PLUGIN %s %s device=%s threads=%d backend=%s\n", api->name,
              api->version, device, runtime.threads, runtime.backend);
  int failed = 0;
  for (int trial = 0; trial < 4; ++trial) {
    api->reset_cancellation(handle);
    Progress s{api, handle};
    jlexa_benchmark_result result{};
    const auto code = bench->run(handle, progress, &s, &result, error, sizeof(error));
    const bool passed = code == 0 && result.source_tokens == 100 &&
        result.generated_tokens > 0 && result.generated_tokens <= 100 &&
        result.prefill_us > 0 && result.decode_us > 0 && !s.output.empty();
    failed += !passed;
    std::printf("BENCH trial=%d source=%u prompt=%u generated=%u decoded=%u prefill_us=%llu decode_us=%llu prefill_tps=%.3f decode_tps=%.3f result=%s\n",
      trial, result.source_tokens, result.prompt_tokens, result.generated_tokens,
      result.decoded_tokens, (unsigned long long)result.prefill_us,
      (unsigned long long)result.decode_us,
      result.prompt_tokens * 1e6 / result.prefill_us,
      result.decoded_tokens * 1e6 / result.decode_us, passed ? "PASS" : "FAIL");
    std::printf("SOURCE %s\nANSWER %s\nERROR %s\n", s.source.c_str(), s.output.c_str(), error);
  }
  api->reset_cancellation(handle);
  Progress cancelled{api, handle}; cancelled.cancel_after = 5;
  jlexa_benchmark_result cancelled_result{};
  auto cancelled_code = bench->run(handle, progress, &cancelled, &cancelled_result, error, sizeof(error));
  failed += cancelled_code != 1;
  std::printf("CANCEL code=%d output=%s\n", cancelled_code, cancelled.output.c_str());
  for (const auto &fixture : {std::pair<const char *, const char *>(
           "What is 2 plus 2? Reply with only the number.", "4"),
           {"Translate into Chinese: Good morning.", "早上好。"}}) {
    api->reset_cancellation(handle);
    jlexa_message messages[]{{"system", "You are a helpful assistant."}, {"user", fixture.first}};
    jlexa_generation g{fixture.first, 32, 0.0f, 0.9f, 1234, 2, messages};
    std::string output;
    auto code = api->generate(handle, &g, [](void *p, const char *text) {
      *static_cast<std::string *>(p) += text;
    }, &output, error, sizeof(error));
    auto normalized = output;
    normalized.erase(std::remove_if(normalized.begin(), normalized.end(),
        [](unsigned char c) { return std::isspace(c); }), normalized.end());
    bool passed = !code && normalized == fixture.second;
    failed += !passed;
    std::printf("SMOKE %s answer=%s error=%s\n", passed ? "PASS" : "FAIL", output.c_str(), error);
  }
  api->destroy(handle);
  dlclose(library);
  return failed ? 1 : 0;
}
