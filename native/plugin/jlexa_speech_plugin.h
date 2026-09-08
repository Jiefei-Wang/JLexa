#ifndef JLEXA_SPEECH_PLUGIN_H
#define JLEXA_SPEECH_PLUGIN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define JLEXA_SPEECH_ABI 1u
// PCM input: mono float32, 16000 Hz. UTF-8 strings and callback data are
// borrowed only for the call. No allocations or C++ objects cross this ABI.
typedef struct {
    const char *text;
    int64_t start_ms, end_ms;
    float confidence;
} jlexa_speech_token;
typedef struct {
    const char *text;
    int64_t start_ms, end_ms;
    float confidence;
    uint32_t token_count;
    const jlexa_speech_token *tokens;
} jlexa_speech_segment;
typedef void (*jlexa_speech_progress_fn)(void *, int32_t percent);
typedef void (*jlexa_speech_segment_fn)(void *, const jlexa_speech_segment *);
typedef struct {
    uint32_t abi_version, struct_size;
    const char *name, *engine, *version, *backend_type;
    void *(*create)(char *error, uint32_t capacity);
    void (*destroy)(void *);
    int32_t (*load_model)(void *, const char *path, char *error, uint32_t capacity);
    void (*unload_model)(void *);
    int32_t (*is_model_loaded)(void *);
    // Synchronous callbacks on the caller thread; 0 success, 1 stopped, -1 error.
    int32_t (*transcribe)(void *, const float *, uint32_t sample_count,
        int32_t threads, const char *language, jlexa_speech_progress_fn,
        jlexa_speech_segment_fn, void *user, char *error, uint32_t capacity);
    // stop is thread-safe. Cancellation stays latched until explicit reset.
    void (*stop)(void *);
    void (*reset_cancellation)(void *);
} jlexa_speech_api;
__attribute__((visibility("default")))
const jlexa_speech_api *jlexa_speech_plugin_get_api(void);
#ifdef __cplusplus
}
#endif
#endif
