// Android standalone fixture: substitute only the loader functions in this
// executable to simulate devices without a driver or a required entry point.
#include "jlexa_opencl_api.h"
#include "ggml-backend.h"
#include "ggml-opencl.h"
#include <atomic>
#include <cstdio>
#include <thread>
#include <vector>
#include <cstring>

static bool missingSymbol;
static std::atomic<int> opens{0}, registrations{0};
extern "C" void *dlopen(const char *name, int) {
    if (name && std::strcmp(name, "libOpenCL.so") == 0) ++opens;
    return missingSymbol ? reinterpret_cast<void *>(1) : nullptr;
}
extern "C" void *dlsym(void *, const char *) { return nullptr; }
extern "C" ggml_backend_reg_t ggml_backend_opencl_reg() { ++registrations; return nullptr; }
extern "C" size_t ggml_backend_reg_dev_count(ggml_backend_reg_t) { ++registrations; return 0; }
extern "C" void ggml_backend_register(ggml_backend_reg_t) { ++registrations; }

int main(int argc, char **) {
    missingSymbol = argc > 1;
    std::vector<std::thread> threads;
    for (int i = 0; i < 8; ++i) threads.emplace_back(jlexa_opencl::registerMaliBackend);
    for (auto &thread : threads) thread.join();
    const std::string reason = jlexa_opencl::unavailableReason();
    std::printf("Driver opens: %d; backend registrations: %d\n", opens.load(), registrations.load());
    bool passed = opens == 1 && registrations == 0 && !reason.empty();
    passed &= reason.find(missingSymbol ? "required API" : "accessible OpenCL driver") != std::string::npos;
    std::printf("OpenCL %s: %s (%s)\n", missingSymbol ? "missing API" : "missing driver",
                passed ? "PASS" : "FAIL", reason.c_str());
    return passed ? 0 : 1;
}
