// Deterministic ABI test backend; intentionally not a language model.
#include "jlexa_plugin.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef FIXTURE_API
#define FIXTURE_API 1
#endif
typedef struct {
  int loaded;
  atomic_int stopped;
} state;
static void *create(char *error, uint32_t n) {
#ifdef FIXTURE_LINK_FAILURE
  extern void jlexa_deliberately_missing_dependency(void);
  jlexa_deliberately_missing_dependency();
#endif
#ifdef FIXTURE_CRASH
  abort();
#endif
#ifdef FIXTURE_FAIL
  snprintf(error, n, "Intentional fixture initialization failure");
  return NULL;
#endif
  return calloc(1, sizeof(state));
}
static int32_t load(void *p, const char *path, const jlexa_runtime *r, char *e,
                    uint32_t n) {
  ((state *)p)->loaded = 1;
  return 0;
}
static void unload(void *p) { ((state *)p)->loaded = 0; }
static int32_t generate(void *p, const jlexa_generation *g, jlexa_token_fn fn,
                        void *u, char *e, uint32_t n) {
  if (!((state *)p)->loaded) {
    snprintf(e, n, "No model loaded");
    return -1;
  }
  if (atomic_load(&((state *)p)->stopped))
    return 1;
  fn(u, "JLexa ABI fixture response");
  return 0;
}
static void stop(void *p) { atomic_store(&((state *)p)->stopped, 1); }
static void reset(void *p) { atomic_store(&((state *)p)->stopped, 0); }
static int32_t loaded(void *p) { return ((state *)p)->loaded; }
static uint32_t devices(void *p, jlexa_device *out, uint32_t n) {
  if (!n)
    return 0;
  memset(out, 0, sizeof(*out));
  strcpy(out->backend, "cpu");
  strcpy(out->device, "ABI fixture CPU");
  out->compiled = out->available = 1;
  return 1;
}
static void active(void *p, jlexa_runtime *out, char *device, uint32_t n) {
  memset(out, 0, sizeof(*out));
  if (!loaded(p))
    return;
  strcpy(out->backend, "cpu");
  out->context_length = 2048;
  out->threads = 1;
  snprintf(device, n, "ABI fixture CPU");
}
#ifndef FIXTURE_MISSING
JLEXA_PLUGIN_EXPORT const jlexa_plugin_api *jlexa_plugin_get_api(void) {
  static const jlexa_plugin_api api = {FIXTURE_API,
                                       sizeof(jlexa_plugin_api),
                                       "JLexa ABI Fixture",
                                       "Test fixture",
                                       "1.0.0",
                                       "CPU",
                                       create,
                                       free,
                                       load,
                                       unload,
                                       generate,
                                       stop,
                                       reset,
                                       loaded,
                                       devices,
                                       active};
  return &api;
}
#else
JLEXA_PLUGIN_EXPORT int unrelated_symbol(void) { return 1; }
#endif
