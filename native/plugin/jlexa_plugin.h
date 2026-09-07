#ifndef JLEXA_PLUGIN_H
#define JLEXA_PLUGIN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define JLEXA_PLUGIN_ABI 1u
#define JLEXA_PLUGIN_EXPORT __attribute__((visibility("default")))
// ABI v1: UTF-8, fixed-width integers, no C++ objects or ownership across DLLs.
// Strings are borrowed for the duration of the call. Output structs are
// caller-owned.
typedef struct {
  char backend[32], device[256], reason[256];
  int32_t compiled, available;
} jlexa_device;
typedef struct {
  char backend[32];
  int32_t context_length, threads, gpu_layers, batch_size, micro_batch_size,
      flash_attention;
} jlexa_runtime;
typedef struct {
  const char *role, *content;
} jlexa_message;
typedef void (*jlexa_token_fn)(void *user, const char *utf8);
typedef struct {
  const char *prompt;
  int32_t max_tokens;
  float temperature, top_p;
  uint32_t seed, message_count;
  const jlexa_message *messages;
} jlexa_generation;
typedef struct {
  uint32_t abi_version, struct_size;
  const char *name, *engine, *version, *backend_type;
  void *(*create)(char *error, uint32_t error_capacity);
  void (*destroy)(void *backend);
  int32_t (*load_model)(void *, const char *path, const jlexa_runtime *,
                        char *error, uint32_t);
  void (*unload_model)(void *);
  // Synchronous; callbacks occur on the calling thread and end before return.
  // 0 = success, 1 = cancelled, -1 = error. stop is thread-safe.
  int32_t (*generate)(void *, const jlexa_generation *, jlexa_token_fn, void *,
                      char *error, uint32_t);
  void (*stop)(void *);
  void (*reset_cancellation)(void *);
  int32_t (*is_model_loaded)(void *);
  uint32_t (*devices)(void *, jlexa_device *out, uint32_t capacity);
  void (*active_runtime)(void *, jlexa_runtime *out, char *device,
                         uint32_t capacity);
} jlexa_plugin_api;
// The sole required symbol. The returned table lives until dlclose.
JLEXA_PLUGIN_EXPORT const jlexa_plugin_api *jlexa_plugin_get_api(void);
#ifdef __cplusplus
}
#endif
#endif
