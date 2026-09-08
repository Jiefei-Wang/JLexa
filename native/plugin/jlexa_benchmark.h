#ifndef JLEXA_BENCHMARK_H
#define JLEXA_BENCHMARK_H
#include "jlexa_plugin.h"
#ifdef __cplusplus
extern "C" {
#endif
// Optional extension. Existing ABI-v1 inference plugins remain valid without it.
#define JLEXA_BENCHMARK_ABI 1u
typedef struct {
  uint32_t source_tokens, prompt_tokens, generated_tokens, decoded_tokens;
  uint64_t prefill_us, decode_us;
} jlexa_benchmark_result;
// 0: source text, 1: completed prefill, 2: output text. Synchronous callbacks.
typedef void (*jlexa_benchmark_progress_fn)(void *, uint32_t phase, const char *,
                                           const jlexa_benchmark_result *);
typedef struct {
  uint32_t abi_version, struct_size;
  // Fixed English->Chinese translation, 100 source tokens, <=100 output tokens.
  // Same cancellation/return/error contracts as generate in the base ABI.
  int32_t (*run)(void *, jlexa_benchmark_progress_fn, void *,
                 jlexa_benchmark_result *, char *error, uint32_t capacity);
} jlexa_benchmark_api;
JLEXA_PLUGIN_EXPORT const jlexa_benchmark_api *jlexa_plugin_get_benchmark_api(void);
#ifdef __cplusplus
}
#endif
#endif
