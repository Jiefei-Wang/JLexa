// Reuse the maintained ABI adapter; only CPU code generation differs.
#define jlexa_plugin_get_api jlexa_llama_original_api
#include "../plugin/llama_plugin.cpp"
#undef jlexa_plugin_get_api
#include <asm/hwcap.h>
#include <sys/auxv.h>

static void *create_checked(char *error, uint32_t capacity) {
#if JLEXA_SNAPDRAGON_OPTIMIZED
  const auto hwcap = getauxval(AT_HWCAP);
  const auto hwcap2 = getauxval(AT_HWCAP2);
  if (!(hwcap & HWCAP_ASIMDDP) || !(hwcap & HWCAP_ASIMDHP) ||
      !(hwcap2 & HWCAP2_I8MM)) {
    copy(error, capacity,
         "Snapdragon CPU plugin requires ARM dotprod, FP16 and i8mm support.");
    return nullptr;
  }
#endif
  return jlexa_llama_original_api()->create(error, capacity);
}

extern "C" JLEXA_PLUGIN_EXPORT const jlexa_plugin_api *jlexa_plugin_get_api() {
  static const jlexa_plugin_api api = [] {
    auto value = *jlexa_llama_original_api();
#if JLEXA_SNAPDRAGON_OPTIMIZED
    value.name = "JLexa Snapdragon CPU";
#else
    value.name = "JLexa ARM64 CPU baseline";
#endif
    value.version = "1.0.0";
    value.backend_type = "CPU";
    value.create = create_checked;
    return value;
  }();
  return &api;
}
