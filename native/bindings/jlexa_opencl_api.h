#pragma once
#define CL_TARGET_OPENCL_VERSION 300
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#include <CL/cl.h>
#include <string>

// Resolve the optional vendor API at runtime. The APK never packages or has a
// DT_NEEDED dependency on a device's proprietary libOpenCL.so.
#define JLEXA_OPENCL_API_FUNCTIONS(X) \
    X(clBuildProgram) X(clCreateBuffer) X(clCreateBufferWithProperties) \
    X(clCreateCommandQueue) X(clCreateContext) X(clCreateImage) X(clCreateKernel) \
    X(clCreateProgramWithBinary) X(clCreateProgramWithSource) X(clCreateSubBuffer) \
    X(clEnqueueBarrierWithWaitList) X(clEnqueueCopyBuffer) X(clEnqueueFillBuffer) \
    X(clEnqueueMarkerWithWaitList) X(clEnqueueNDRangeKernel) X(clEnqueueReadBuffer) \
    X(clEnqueueWriteBuffer) X(clFinish) X(clFlush) X(clGetDeviceIDs) \
    X(clGetDeviceInfo) X(clGetEventProfilingInfo) X(clGetKernelInfo) \
    X(clGetKernelSubGroupInfo) X(clGetKernelWorkGroupInfo) X(clGetPlatformIDs) \
    X(clGetPlatformInfo) X(clGetProgramBuildInfo) X(clGetProgramInfo) \
    X(clReleaseEvent) X(clReleaseKernel) X(clReleaseMemObject) X(clReleaseProgram) \
    X(clSetKernelArg) X(clWaitForEvents)

namespace jlexa_opencl {
struct Api {
#define JLEXA_DECLARE(name) decltype(&::name) name = nullptr;
    JLEXA_OPENCL_API_FUNCTIONS(JLEXA_DECLARE)
#undef JLEXA_DECLARE
};
Api &api();
// Thread-safe, idempotent registration. Failure leaves CPU/Vulkan usable.
void registerMaliBackend();
std::string unavailableReason();
} // namespace jlexa_opencl
