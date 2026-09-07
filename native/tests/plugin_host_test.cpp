#include "jlexa_backend_host.h"
#include <cassert>
#include <cstdio>
#include <string>
int main(int argc, char **argv) {
  assert(argc == 3);
  auto &h = JLexaBackendHost::instance();
  if (std::string(argv[1]) == "reject") {
    try {
      h.select(argv[2]);
    } catch (const std::exception &e) {
      printf("REJECTED: %s\n", e.what());
      return 0;
    }
    return 2;
  }
  h.select(argv[2]);
  assert(h.pluginInfo()[0] == "JLexa ABI Fixture");
  assert(h.getAvailableBackends()[0].backend == "cpu");
  assert(!h.isModelLoaded());
  h.loadModel("fixture-model", JLexaLlamaRuntimeConfig{});
  assert(h.isModelLoaded());
  std::string text;
  bool done = false;
  h.generate(
      "hello", 16, 0.1, 0.9, 0, {}, [&](const std::string &t) { text += t; },
      [&](bool c, const std::string &e) {
        assert(!c && e.empty());
        done = true;
      });
  assert(done && text == "JLexa ABI fixture response");
  h.cancel();
  h.generate(
      "hello", 16, 0.1, 0.9, 0, {}, [](const std::string &) { assert(false); },
      [](bool c, const std::string &e) { assert(c); });
  h.resetCancellation();
  h.unloadModel();
  assert(!h.isModelLoaded());
  h.select(argv[2]);
  assert(!h.isModelLoaded());
  puts("PASS: ABI info, create, load, generate, cancel, reset, unload, "
       "destroy/recreate");
}
