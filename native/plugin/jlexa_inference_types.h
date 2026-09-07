#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <vector>
struct JLexaChatMessage {
  std::string role;
  std::string content;
};

struct JLexaBackendInfo {
  std::string backend; // "cpu", "vulkan", "opencl"
  bool compiled;
  bool available;
  std::string deviceName;
  std::string reasonUnavailable;
};

struct JLexaActiveBackendInfo {
  std::string backend;
  std::string deviceName;
  int gpuLayers;
  int contextLength;
  int threads;
  int batchSize;
  int ubatchSize;
  int flashAttention; // -1 auto, 0 off, 1 on
};

struct JLexaLlamaRuntimeConfig {
  std::string backend = "auto"; // "auto", "cpu", "vulkan", "opencl"
  int contextLength = 2048;
  int n_threads = 4;
  int gpuLayers = -1; // -1 auto/all (when accelerated), 0 none, >0 custom
  int batchSize = 512;
  int ubatchSize = 512;
  int flashAttention = -1; // -1 auto, 0 disabled, 1 enabled
};
