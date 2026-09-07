#include "jlexa_llama_bridge.h"
#include "jlexa_plugin.h"
#include <algorithm>
#include <cstdio>
#include <exception>
static void copy(char *out, uint32_t n, const std::string &s) {
  if (n)
    std::snprintf(out, n, "%s", s.c_str());
}
static JLexaLlamaBridge &bridge(void *p) {
  return *static_cast<JLexaLlamaBridge *>(p);
}
static void *create(char *e, uint32_t n) {
  try {
    return &JLexaLlamaBridge::instance();
  } catch (const std::exception &x) {
    copy(e, n, x.what());
    return nullptr;
  }
}
static void destroy(void *p) { bridge(p).unloadModel(); }
static int32_t load(void *p, const char *path, const jlexa_runtime *r, char *e,
                    uint32_t n) {
  try {
    JLexaLlamaRuntimeConfig c;
    c.backend = r->backend;
    c.contextLength = r->context_length;
    c.n_threads = r->threads;
    c.gpuLayers = r->gpu_layers;
    c.batchSize = r->batch_size;
    c.ubatchSize = r->micro_batch_size;
    c.flashAttention = r->flash_attention;
    if (bridge(p).loadModel(path, c))
      return 0;
    copy(e, n, "The selected AI model could not be loaded.");
  } catch (const std::exception &x) {
    copy(e, n, x.what());
  }
  return -1;
}
static int32_t generate(void *p, const jlexa_generation *g,
                        jlexa_token_fn token, void *user, char *e, uint32_t n) {
  try {
    std::vector<JLexaChatMessage> messages;
    for (uint32_t i = 0; i < g->message_count; i++)
      messages.push_back({g->messages[i].role, g->messages[i].content});
    int32_t result = 0;
    bridge(p).generate(
        g->prompt, g->max_tokens, g->temperature, g->top_p, g->seed, messages,
        [&](const std::string &s) { token(user, s.c_str()); },
        [&](bool cancelled, const std::string &error) {
          result = cancelled ? 1 : error.empty() ? 0 : -1;
          copy(e, n, error);
        });
    return result;
  } catch (const std::exception &x) {
    copy(e, n, x.what());
    return -1;
  }
}
static uint32_t devices(void *p, jlexa_device *out, uint32_t capacity) {
  auto ds = bridge(p).getAvailableBackends();
  uint32_t count = std::min(capacity, static_cast<uint32_t>(ds.size()));
  for (uint32_t i = 0; i < count; i++) {
    copy(out[i].backend, sizeof(out[i].backend), ds[i].backend);
    copy(out[i].device, sizeof(out[i].device), ds[i].deviceName);
    copy(out[i].reason, sizeof(out[i].reason), ds[i].reasonUnavailable);
    out[i].compiled = ds[i].compiled;
    out[i].available = ds[i].available;
  }
  return count;
}
static void active(void *p, jlexa_runtime *out, char *device, uint32_t n) {
  auto a = bridge(p).getActiveBackendInfo();
  copy(out->backend, sizeof(out->backend), a.backend);
  copy(device, n, a.deviceName);
  out->context_length = a.contextLength;
  out->threads = a.threads;
  out->gpu_layers = a.gpuLayers;
  out->batch_size = a.batchSize;
  out->micro_batch_size = a.ubatchSize;
  out->flash_attention = a.flashAttention;
}
extern "C" JLEXA_PLUGIN_EXPORT const jlexa_plugin_api *jlexa_plugin_get_api() {
  static const jlexa_plugin_api api = {
      JLEXA_PLUGIN_ABI,
      sizeof(jlexa_plugin_api),
      "JLexa llama.cpp",
      "llama.cpp",
      "1.0.0",
      "CPU / Vulkan / OpenCL",
      create,
      destroy,
      load,
      [](void *p) { bridge(p).unloadModel(); },
      generate,
      [](void *p) { bridge(p).cancel(); },
      [](void *p) { bridge(p).resetCancellation(); },
      [](void *p) -> int32_t { return bridge(p).isModelLoaded(); },
      devices,
      active};
  return &api;
}
