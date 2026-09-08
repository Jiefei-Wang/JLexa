#pragma once
#include "jlexa_inference_types.h"
#include "jlexa_plugin.h"
#include "jlexa_benchmark.h"
#include <memory>
#include <mutex>
class JLexaBackendHost {
public:
  static JLexaBackendHost &instance();
  void select(const std::string &path);
  std::vector<std::string> pluginInfo();
  std::vector<JLexaBackendInfo> getAvailableBackends();
  JLexaActiveBackendInfo getActiveBackendInfo();
  bool loadModel(const std::string &, const JLexaLlamaRuntimeConfig &);
  void unloadModel();
  bool isModelLoaded();
  void generate(const std::string &, int, float, float, uint32_t,
                const std::vector<JLexaChatMessage> &,
                std::function<void(const std::string &)>,
                std::function<void(bool, const std::string &)>);
  void cancel();
  void resetCancellation();
  bool supportsBenchmark();
  int benchmark(jlexa_benchmark_result &, std::function<void(uint32_t, const std::string &, const jlexa_benchmark_result &)>);

private:
  struct Backend;
  std::shared_ptr<Backend> current();
  std::shared_ptr<Backend> active;
  std::recursive_mutex operations;
  std::mutex state;
};
