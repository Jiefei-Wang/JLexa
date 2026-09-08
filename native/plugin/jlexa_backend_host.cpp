#include "jlexa_backend_host.h"
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

struct JLexaBackendHost::Backend {
  void *library = nullptr, *handle = nullptr;
  const jlexa_plugin_api *api = nullptr;
  explicit Backend(const std::string &path) {
    if (!path.empty()) {
      int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
      Elf64_Ehdr h{};
      struct stat st {};
      bool valid = fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
                   read(fd, &h, sizeof(h)) == sizeof(h) &&
                   !memcmp(h.e_ident, ELFMAG, SELFMAG) &&
                   h.e_ident[EI_CLASS] == ELFCLASS64 &&
                   h.e_ident[EI_DATA] == ELFDATA2LSB &&
                   h.e_machine == EM_AARCH64 && h.e_type == ET_DYN;
      if (fd >= 0)
        close(fd);
      if (!valid)
        throw std::runtime_error(
            "Incompatible: expected an Android arm64-v8a ELF shared library.");
      if (st.st_mode & 0222)
        throw std::runtime_error("Failed: plugin file must be read-only.");
    }
    library = dlopen(path.empty() ? "libjlexa_llama.so" : path.c_str(),
                     RTLD_NOW | RTLD_LOCAL);
    if (!library)
      throw std::runtime_error(std::string("Failed: dlopen: ") + dlerror());
    try {
      auto entry = reinterpret_cast<const jlexa_plugin_api *(*)()>(
          dlsym(library, "jlexa_plugin_get_api"));
      if (!entry)
        throw std::runtime_error(
            "Incompatible: missing jlexa_plugin_get_api symbol.");
      api = entry();
      if (!api || api->abi_version != JLEXA_PLUGIN_ABI ||
          api->struct_size < sizeof(jlexa_plugin_api))
        throw std::runtime_error(
            "Incompatible: expected JLexa plugin API version 1.");
      if (!api->name || !api->engine || !api->version || !api->backend_type ||
          !api->create || !api->destroy || !api->load_model ||
          !api->unload_model || !api->generate || !api->stop ||
          !api->reset_cancellation || !api->is_model_loaded || !api->devices ||
          !api->active_runtime)
        throw std::runtime_error(
            "Incompatible: incomplete JLexa plugin API table.");
      char error[1024]{};
      handle = api->create(error, sizeof(error));
      error[1023] = 0;
      if (!handle)
        throw std::runtime_error(
            std::string("Failed: backend initialization: ") + error);
    } catch (...) {
      dlclose(library);
      library = nullptr;
      throw;
    }
  }
  ~Backend() {
    if (handle)
      api->destroy(handle);
    if (library)
      dlclose(library);
  }
};
JLexaBackendHost &JLexaBackendHost::instance() {
  static JLexaBackendHost h;
  return h;
}
bool JLexaBackendHost::supportsBenchmark() {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  auto get = reinterpret_cast<const jlexa_benchmark_api *(*)()>(
      dlsym(b->library, "jlexa_plugin_get_benchmark_api"));
  if (!get) return false;
  const auto *api = get();
  return api && api->abi_version == JLEXA_BENCHMARK_ABI &&
         api->struct_size >= sizeof(jlexa_benchmark_api) && api->run;
}
int JLexaBackendHost::benchmark(jlexa_benchmark_result &stats,
    std::function<void(uint32_t, const std::string &, const jlexa_benchmark_result &)> progress) {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  if (!supportsBenchmark()) throw std::runtime_error("This plugin does not support native benchmark timing. Update the plugin to benchmark it.");
  auto get = reinterpret_cast<const jlexa_benchmark_api *(*)()>(
      dlsym(b->library, "jlexa_plugin_get_benchmark_api"));
  char error[1024]{};
  int result = get()->run(b->handle,
      [](void *u, uint32_t phase, const char *text, const jlexa_benchmark_result *s) {
        if (s) (*static_cast<decltype(progress)*>(u))(phase, text ? text : "", *s);
      }, &progress, &stats, error, sizeof(error));
  error[1023] = 0;
  if (result < 0) throw std::runtime_error(error[0] ? error : "Native benchmark failed");
  return result;
}
std::shared_ptr<JLexaBackendHost::Backend> JLexaBackendHost::current() {
  std::lock_guard<std::mutex> l(state);
  if (!active)
    active = std::make_shared<Backend>("");
  return active;
}
void JLexaBackendHost::select(const std::string &path) {
  std::lock_guard<std::recursive_mutex> op(operations);
  // Destroy before create: the bundled adapter deliberately has one model
  // instance.
  {
    std::lock_guard<std::mutex> l(state);
    active.reset();
  }
  auto next = std::make_shared<Backend>(path);
  std::lock_guard<std::mutex> l(state);
  active = std::move(next);
}
std::vector<std::string> JLexaBackendHost::pluginInfo() {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  return {b->api->name, b->api->engine, b->api->version, b->api->backend_type};
}
std::vector<JLexaBackendInfo> JLexaBackendHost::getAvailableBackends() {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  jlexa_device ds[16]{};
  uint32_t n = std::min(b->api->devices(b->handle, ds, 16), 16u);
  std::vector<JLexaBackendInfo> out;
  for (uint32_t i = 0; i < n; i++) {
    ds[i].backend[31] = 0;
    ds[i].device[255] = 0;
    ds[i].reason[255] = 0;
    out.push_back({ds[i].backend, ds[i].compiled != 0, ds[i].available != 0,
                   ds[i].device, ds[i].reason});
  }
  return out;
}
JLexaActiveBackendInfo JLexaBackendHost::getActiveBackendInfo() {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  jlexa_runtime r{};
  char device[256]{};
  b->api->active_runtime(b->handle, &r, device, sizeof(device));
  r.backend[31] = 0;
  device[255] = 0;
  return {r.backend, device,       r.gpu_layers,       r.context_length,
          r.threads, r.batch_size, r.micro_batch_size, r.flash_attention};
}
bool JLexaBackendHost::loadModel(const std::string &path,
                                 const JLexaLlamaRuntimeConfig &c) {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  jlexa_runtime r{};
  std::snprintf(r.backend, sizeof(r.backend), "%s", c.backend.c_str());
  r.context_length = c.contextLength;
  r.threads = c.n_threads;
  r.gpu_layers = c.gpuLayers;
  r.batch_size = c.batchSize;
  r.micro_batch_size = c.ubatchSize;
  r.flash_attention = c.flashAttention;
  char error[1024]{};
  int result =
      b->api->load_model(b->handle, path.c_str(), &r, error, sizeof(error));
  error[1023] = 0;
  if (result != 0)
    throw std::runtime_error(error[0] ? error : "Plugin model load failed.");
  return true;
}
void JLexaBackendHost::unloadModel() {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  b->api->unload_model(b->handle);
}
bool JLexaBackendHost::isModelLoaded() {
  std::lock_guard<std::recursive_mutex> op(operations);
  auto b = current();
  return b->api->is_model_loaded(b->handle) != 0;
}
void JLexaBackendHost::cancel() {
  auto b = current();
  b->api->stop(b->handle);
}
void JLexaBackendHost::resetCancellation() {
  auto b = current();
  b->api->reset_cancellation(b->handle);
}
void JLexaBackendHost::generate(
    const std::string &prompt, int tokens, float temperature, float topP,
    uint32_t seed, const std::vector<JLexaChatMessage> &messages,
    std::function<void(const std::string &)> token,
    std::function<void(bool, const std::string &)> complete) {
  std::lock_guard<std::recursive_mutex> op(operations);
  try {
    auto b = current();
    std::vector<jlexa_message> ms;
    for (auto &m : messages)
      ms.push_back({m.role.c_str(), m.content.c_str()});
    jlexa_generation g{prompt.c_str(), tokens, temperature,
                       topP,           seed,   static_cast<uint32_t>(ms.size()),
                       ms.data()};
    char error[1024]{};
    int result = b->api->generate(
        b->handle, &g,
        [](void *u, const char *s) {
          (*static_cast<std::function<void(const std::string &)> *>(u))(s ? s
                                                                          : "");
        },
        &token, error, sizeof(error));
    error[1023] = 0;
    complete(result == 1, result < 0
                              ? (error[0] ? error : "Plugin generation failed.")
                              : "");
  } catch (const std::exception &e) {
    complete(false, e.what());
  }
}
