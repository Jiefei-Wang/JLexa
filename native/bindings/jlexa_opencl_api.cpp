#include "jlexa_opencl_api.h"
#include "ggml-backend.h"
#include "ggml-opencl.h"
#include <dlfcn.h>
#include <mutex>
#include <exception>

namespace jlexa_opencl {
namespace {
Api functions;
std::once_flag registration;
std::string reason = "Experimental OpenCL supports Mali-G78 Q4_K/Q6_K matrix multiplication with CPU fallback.";
// The backend's queues/programs live for the process; retain its vendor library.
void *driver = nullptr;
}

Api &api() { return functions; }

void registerMaliBackend() {
    std::call_once(registration, [] {
        driver = dlopen("libOpenCL.so", RTLD_NOW | RTLD_LOCAL);
        if (!driver) {
            reason = "The device does not expose an accessible OpenCL driver to this app.";
            return;
        }
#define JLEXA_LOAD(name) \
        functions.name = reinterpret_cast<decltype(functions.name)>(dlsym(driver, #name)); \
        if (!functions.name) { reason = "The OpenCL driver lacks required API " #name "."; return; }
        JLEXA_OPENCL_API_FUNCTIONS(JLEXA_LOAD)
#undef JLEXA_LOAD
        try {
            cl_platform_id platforms[16];
            cl_uint platformCount = 0;
            bool maliFound = false;
            if (functions.clGetPlatformIDs(16, platforms, &platformCount) == CL_SUCCESS) {
                for (cl_uint p = 0; p < platformCount && p < 16; ++p) {
                    cl_device_id devices[16];
                    cl_uint deviceCount = 0;
                    if (functions.clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_GPU, 16,
                                                 devices, &deviceCount) != CL_SUCCESS) continue;
                    for (cl_uint d = 0; d < deviceCount && d < 16; ++d) {
                        char name[256] = {};
                        if (functions.clGetDeviceInfo(devices[d], CL_DEVICE_NAME,
                                                     sizeof(name), name, nullptr) != CL_SUCCESS) continue;
                        const std::string deviceName(name);
                        maliFound |= deviceName == "Mali-G78" || deviceName.rfind("Mali-G78 ", 0) == 0;
                    }
                }
            }
            if (!maliFound) {
                reason = "Experimental OpenCL requires Mali-G78; other GPUs are not supported by this build.";
                return;
            }
            ggml_backend_reg_t backend = ggml_backend_opencl_reg();
            if (ggml_backend_reg_dev_count(backend) == 0) {
                reason = "Experimental OpenCL requires a compatible Mali-G78; other GPUs are not supported by this build.";
                return;
            }
            ggml_backend_register(backend);
            reason.clear();
        } catch (const std::exception &error) {
            reason = std::string("OpenCL device initialization failed: ") + error.what();
        } catch (...) {
            reason = "OpenCL device initialization failed.";
        }
    });
}

std::string unavailableReason() {
    registerMaliBackend();
    return reason;
}
} // namespace jlexa_opencl
