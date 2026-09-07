// Standalone Android OpenCL capability/computation probe. No app data is read.
// Build using Khronos OpenCL-Headers and the NDK; link only libdl.
#define CL_TARGET_OPENCL_VERSION 300
#define CL_USE_DEPRECATED_OPENCL_1_2_APIS
#include <CL/cl.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CL_FUNCTIONS(X) \
    X(clGetPlatformIDs) X(clGetPlatformInfo) X(clGetDeviceIDs) \
    X(clGetDeviceInfo) X(clCreateContext) X(clCreateCommandQueue) \
    X(clCreateProgramWithSource) X(clBuildProgram) X(clGetProgramBuildInfo) \
    X(clCreateKernel) X(clCreateBuffer) X(clSetKernelArg) \
    X(clEnqueueNDRangeKernel) X(clEnqueueReadBuffer) X(clFinish) \
    X(clReleaseMemObject) X(clReleaseKernel) X(clReleaseProgram) \
    X(clReleaseCommandQueue) X(clReleaseContext)
#define DECLARE(name) static __typeof__(&name) p_##name;
CL_FUNCTIONS(DECLARE)
#undef DECLARE

static void device_text(cl_device_id device, cl_device_info property, const char *name) {
    char text[16384] = {0};
    cl_int error = p_clGetDeviceInfo(device, property, sizeof(text), text, NULL);
    printf("%s: %s (status %d)\n", name, text, error);
}

static void device_versions(cl_device_id device) {
    cl_name_version versions[32] = {0};
    size_t bytes = 0;
    cl_int error = p_clGetDeviceInfo(device, CL_DEVICE_OPENCL_C_ALL_VERSIONS,
                                    sizeof(versions), versions, &bytes);
    printf("All OpenCL C versions (status %d):", error);
    if (error == CL_SUCCESS) {
        for (size_t i = 0; i < bytes / sizeof(versions[0]) && i < 32; ++i)
            printf(" %s %u.%u", versions[i].name,
                   CL_VERSION_MAJOR(versions[i].version), CL_VERSION_MINOR(versions[i].version));
    }
    printf("\n");
}

static void compile_file(cl_context context, cl_device_id device, const char *path) {
    FILE *file = fopen(path, "rb");
    if (!file) { printf("Cannot read kernel %s\n", path); return; }
    fseek(file, 0, SEEK_END);
    long bytes = ftell(file);
    rewind(file);
    if (bytes <= 0) { fclose(file); return; }
    char *source = calloc((size_t)bytes + 1, 1);
    if (!source) { fclose(file); return; }
    if (fread(source, 1, (size_t)bytes, file) != (size_t)bytes) {
        fclose(file); free(source); return;
    }
    fclose(file);
    const char *src = source;
    cl_int error;
    cl_program program = p_clCreateProgramWithSource(context, 1, &src, NULL, &error);
    if (program && error == CL_SUCCESS) {
        error = p_clBuildProgram(program, 1, &device, "-cl-std=CL3.0", NULL, NULL);
        printf("Unmodified kernel %s build: %d\n", path, error);
        char log[16384] = {0};
        p_clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
        printf("%s\n", log);
        p_clReleaseProgram(program);
    }
    free(source);
}

static int kernel_test(cl_context context, cl_command_queue queue, cl_device_id device,
                       const char *name, const char *source, const char *options,
                       float expected, float increment, size_t local_size) {
    cl_int error;
    cl_program program = p_clCreateProgramWithSource(context, 1, &source, NULL, &error);
    if (!program || error != CL_SUCCESS) return 1;
    error = p_clBuildProgram(program, 1, &device, options, NULL, NULL);
    printf("%s build: %d; options: %s\n", name, error, options);
    if (error != CL_SUCCESS) {
        char log[16384] = {0};
        p_clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG, sizeof(log), log, NULL);
        printf("%s\n", log);
        p_clReleaseProgram(program);
        return 1;
    }
    cl_kernel kernel = p_clCreateKernel(program, "probe", &error);
    if (!kernel || error != CL_SUCCESS) {
        p_clReleaseProgram(program);
        return 1;
    }
    float output[256] = {0};
    cl_mem buffer = p_clCreateBuffer(context, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR,
                                   sizeof(output), output, &error);
    int failed = !buffer || error != CL_SUCCESS;
    if (!failed) {
        error = p_clSetKernelArg(kernel, 0, sizeof(buffer), &buffer);
        const size_t global_size = 256;
        if (error == CL_SUCCESS)
            error = p_clEnqueueNDRangeKernel(queue, kernel, 1, NULL, &global_size,
                                            &local_size, 0, NULL, NULL);
        if (error == CL_SUCCESS)
            error = p_clEnqueueReadBuffer(queue, buffer, CL_TRUE, 0, sizeof(output),
                                          output, 0, NULL, NULL);
        failed = error != CL_SUCCESS;
        for (size_t i = 0; i < 256 && !failed; ++i) {
            if (expected >= 0 ? output[i] != expected + increment * i
                              : output[i] <= 0 || output[i] != output[0]) failed = 1;
        }
        printf("%s execution: %s (status %d; first=%g, expected=%g, local=%zu)\n",
               name, failed ? "FAIL" : "PASS", error, output[0], expected, local_size);
        p_clReleaseMemObject(buffer);
    }
    p_clReleaseKernel(kernel);
    p_clReleaseProgram(program);
    return failed;
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    const char *library = argc > 1 ? argv[1] : "libOpenCL.so";
    printf("Loading %s\n", library);
    void *handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        printf("dlopen failed: %s\n", dlerror());
        return 1;
    }
#define LOAD(name) do { \
    p_##name = (__typeof__(p_##name))dlsym(handle, #name); \
    if (!p_##name) { printf("Missing %s\n", #name); return 1; } \
} while (0);
    CL_FUNCTIONS(LOAD)
#undef LOAD
    cl_platform_id platforms[16];
    cl_uint platform_count = 0;
    cl_int error = p_clGetPlatformIDs(16, platforms, &platform_count);
    printf("Platforms: %u (status %d)\n", platform_count, error);
    if (error != CL_SUCCESS || !platform_count) return 1;
    int basic_failures = 0;
    for (cl_uint i = 0; i < platform_count && i < 16; ++i) {
        char name[1024] = {0}, version[1024] = {0};
        p_clGetPlatformInfo(platforms[i], CL_PLATFORM_NAME, sizeof(name), name, NULL);
        p_clGetPlatformInfo(platforms[i], CL_PLATFORM_VERSION, sizeof(version), version, NULL);
        printf("Platform: %s; %s\n", name, version);
        cl_device_id devices[16];
        cl_uint device_count = 0;
        error = p_clGetDeviceIDs(platforms[i], CL_DEVICE_TYPE_GPU, 16, devices, &device_count);
        printf("GPU devices: %u (status %d)\n", device_count, error);
        if (error != CL_SUCCESS || !device_count) { ++basic_failures; continue; }
        for (cl_uint d = 0; d < device_count && d < 16; ++d) {
            const cl_device_id device = devices[d];
            device_text(device, CL_DEVICE_NAME, "Device");
            device_text(device, CL_DEVICE_VENDOR, "Vendor");
            device_text(device, CL_DEVICE_VERSION, "Version");
            device_text(device, CL_DRIVER_VERSION, "Driver");
            device_text(device, CL_DEVICE_OPENCL_C_VERSION, "OpenCL C");
            device_versions(device);
            device_text(device, CL_DEVICE_EXTENSIONS, "Extensions");
            size_t max_group = 0;
            cl_ulong max_alloc = 0;
            p_clGetDeviceInfo(device, CL_DEVICE_MAX_WORK_GROUP_SIZE, sizeof(max_group), &max_group, NULL);
            p_clGetDeviceInfo(device, CL_DEVICE_MAX_MEM_ALLOC_SIZE, sizeof(max_alloc), &max_alloc, NULL);
            printf("Max workgroup: %zu; max allocation: %llu\n", max_group, (unsigned long long)max_alloc);
            cl_context context = p_clCreateContext(NULL, 1, &device, NULL, NULL, &error);
            if (!context || error != CL_SUCCESS) {
                printf("Context failed: %d\n", error); ++basic_failures; continue;
            }
            cl_command_queue queue = p_clCreateCommandQueue(context, device, 0, &error);
            if (!queue || error != CL_SUCCESS) {
                p_clReleaseContext(context); ++basic_failures; continue;
            }
            basic_failures += kernel_test(context, queue, device, "FP32 arithmetic",
                "__kernel void probe(__global float *out) { size_t i = get_global_id(0); out[i] = 2.0f * (float)i + 23.0f; }",
                "-cl-std=CL1.2", 23.0f, 2.0f, 64);
            kernel_test(context, queue, device, "FP16 arithmetic",
                "#pragma OPENCL EXTENSION cl_khr_fp16 : enable\n"
                "__kernel void probe(__global float *out) { size_t i = get_global_id(0); half a = (half)(3 + i); half b = (half)7.0f; out[i] = (float)(a * b); }",
                "-cl-std=CL2.0", 21.0f, 7.0f, 64);
            kernel_test(context, queue, device, "Subgroup reduction",
                "#pragma OPENCL EXTENSION cl_khr_subgroups : enable\n"
                "__kernel void probe(__global float *out) { out[get_global_id(0)] = sub_group_reduce_add(1.0f) / (float)get_sub_group_size(); }",
                "-cl-std=CL2.0", 1.0f, 0.0f, 64);
            kernel_test(context, queue, device, "Observed subgroup size",
                "#pragma OPENCL EXTENSION cl_khr_subgroups : enable\n"
                "__kernel void probe(__global float *out) { out[get_global_id(0)] = (float)get_sub_group_size(); }",
                "-cl-std=CL3.0", -1.0f, 0.0f, 64);
            if (argc > 2) compile_file(context, device, argv[2]);
            p_clFinish(queue);
            p_clReleaseCommandQueue(queue);
            p_clReleaseContext(context);
        }
    }
    dlclose(handle);
    return basic_failures ? 1 : 0;
}
