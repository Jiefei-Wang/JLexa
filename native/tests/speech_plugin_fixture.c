#include "jlexa_speech_plugin.h"
#include <stdlib.h>
#include <stdio.h>
#ifdef SHARED_FD_MODEL
#include <string.h>
#include <unistd.h>
#endif
#ifndef API_VERSION
#define API_VERSION 1
#endif
static void *create(char *error, uint32_t n) {
#ifdef CRASH_INIT
    abort();
#endif
    (void)error; (void)n; return calloc(1, 1);
}
static int32_t load(void *p, const char *path, char *error, uint32_t n) {
#ifdef SHARED_FD_MODEL
    /* Match the SAF adapter's dup(): it shares and advances the owner's offset. */
    const char *prefix = "/proc/self/fd/";
    if (strncmp(path, prefix, strlen(prefix))) return -1;
    int fd = dup(atoi(path + strlen(prefix)));
    char magic[8], buffer[128];
    if (fd < 0 || read(fd, magic, sizeof(magic)) != sizeof(magic) ||
        memcmp(magic, "JLEXAFD1", sizeof(magic))) {
        if (fd >= 0) close(fd);
        if (error && n) snprintf(error, n, "Shared descriptor was not rewound");
        return -1;
    }
    while (read(fd, buffer, sizeof(buffer)) > 0) {}
    close(fd);
#endif
#ifdef FAIL_MODEL
    if (error && n) snprintf(error, n, "Fixture model load failure");
    return -1;
#endif
    (void)path; (void)error; (void)n; *(char *)p = 1; return 0;
}
static void unload(void *p) { *(char *)p = 0; }
static int32_t loaded(void *p) { return *(char *)p; }
static void noop(void *p) { (void)p; }
static int32_t transcribe(void *p, const float *samples, uint32_t count,
    int32_t threads, const char *language, jlexa_speech_progress_fn progress,
    jlexa_speech_segment_fn emit, void *user, char *error, uint32_t n) {
    (void)p; (void)samples; (void)count; (void)threads; (void)language; (void)error; (void)n;
    const jlexa_speech_segment s = {"Speech ABI fixture", 0, 1000, 1, 0, NULL};
    if (progress) progress(user, 100);
    if (emit) emit(user, &s);
    return 0;
}
static const jlexa_speech_api api = {API_VERSION, sizeof(jlexa_speech_api),
    "Speech ABI fixture", "Test", "1", "CPU", create, free, load, unload,
    loaded, transcribe, noop, noop};
const jlexa_speech_api *jlexa_speech_plugin_get_api(void) { return &api; }
